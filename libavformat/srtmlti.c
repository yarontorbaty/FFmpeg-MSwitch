/*
 * SRT Multi-Input demuxer with built-in relay
 * Copyright (c) 2025
 *
 * This demuxer wraps multiple SRT sources with an internal relay,
 * making them appear as simple streams to consumers like mswitchdirect.
 *
 * Usage: srt-multi://source1,source2,source3
 * Example: srt-multi://srt://server1:9000,srt://server2:9000,srt://server3:9000
 */

#include "avformat.h"
#include "demux.h"
#include "libavutil/opt.h"
#include "libavutil/avstring.h"
#include "url.h"

#ifdef CONFIG_LIBSRT
#include <srt/srt.h>
#include <pthread.h>

#define MAX_SOURCES 10
#define BUFFER_SIZE 2048
#define MAX_CLIENTS 10

typedef struct SRTClient {
    SRTSOCKET socket;
    int active;
    pthread_mutex_t mutex;
} SRTClient;

typedef struct SRTSource {
    char *url;
    int relay_input_port;
    int relay_output_port;
    SRTSOCKET input_socket;
    pthread_t input_thread;
    pthread_t output_thread;
    SRTClient clients[MAX_CLIENTS];
    int running;
} SRTSource;

typedef struct SRTMultiContext {
    const AVClass *class;
    char *sources_str;
    int num_sources;
    SRTSource sources[MAX_SOURCES];
    int base_relay_port;
    
    // Current active source for reading
    URLContext *current_source;
    int current_index;
} SRTMultiContext;

// Input thread: accepts source connection and relays to clients
static void* srt_input_thread(void *arg) {
    SRTSource *source = (SRTSource*)arg;
    SRTSOCKET listen_sock = srt_create_socket();
    struct sockaddr_in addr;
    
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(source->relay_input_port);
    
    if (srt_bind(listen_sock, (struct sockaddr*)&addr, sizeof(addr)) == SRT_ERROR) {
        av_log(NULL, AV_LOG_ERROR, "[SRT Multi] Failed to bind input port %d: %s\n",
               source->relay_input_port, srt_getlasterror_str());
        return NULL;
    }
    
    if (srt_listen(listen_sock, 5) == SRT_ERROR) {
        av_log(NULL, AV_LOG_ERROR, "[SRT Multi] Failed to listen on port %d: %s\n",
               source->relay_input_port, srt_getlasterror_str());
        return NULL;
    }
    
    av_log(NULL, AV_LOG_INFO, "[SRT Multi] Relay listening for source on port %d\n",
           source->relay_input_port);
    
    while (source->running) {
        struct sockaddr_in client_addr;
        int addr_len = sizeof(client_addr);
        
        SRTSOCKET client_sock = srt_accept(listen_sock, (struct sockaddr*)&client_addr, &addr_len);
        if (client_sock == SRT_INVALID_SOCK) {
            if (source->running)
                av_log(NULL, AV_LOG_WARNING, "[SRT Multi] Accept failed on port %d\n",
                       source->relay_input_port);
            continue;
        }
        
        av_log(NULL, AV_LOG_INFO, "[SRT Multi] Source connected to relay port %d\n",
               source->relay_input_port);
        source->input_socket = client_sock;
        
        // Relay packets to all clients
        char buffer[BUFFER_SIZE];
        while (source->running) {
            int bytes = srt_recv(client_sock, buffer, BUFFER_SIZE);
            if (bytes <= 0) {
                if (bytes < 0)
                    av_log(NULL, AV_LOG_WARNING, "[SRT Multi] Read error from source on port %d\n",
                           source->relay_input_port);
                break;
            }
            
            // Broadcast to all active clients
            for (int i = 0; i < MAX_CLIENTS; i++) {
                pthread_mutex_lock(&source->clients[i].mutex);
                if (source->clients[i].active) {
                    int sent = srt_send(source->clients[i].socket, buffer, bytes);
                    if (sent < 0) {
                        av_log(NULL, AV_LOG_DEBUG, "[SRT Multi] Client %d disconnected\n", i);
                        source->clients[i].active = 0;
                        srt_close(source->clients[i].socket);
                    }
                }
                pthread_mutex_unlock(&source->clients[i].mutex);
            }
        }
        
        av_log(NULL, AV_LOG_INFO, "[SRT Multi] Source disconnected from relay port %d\n",
               source->relay_input_port);
        srt_close(client_sock);
        source->input_socket = SRT_INVALID_SOCK;
    }
    
    srt_close(listen_sock);
    return NULL;
}

// Output thread: accepts client connections
static void* srt_output_thread(void *arg) {
    SRTSource *source = (SRTSource*)arg;
    SRTSOCKET listen_sock = srt_create_socket();
    struct sockaddr_in addr;
    
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(source->relay_output_port);
    
    if (srt_bind(listen_sock, (struct sockaddr*)&addr, sizeof(addr)) == SRT_ERROR) {
        av_log(NULL, AV_LOG_ERROR, "[SRT Multi] Failed to bind output port %d: %s\n",
               source->relay_output_port, srt_getlasterror_str());
        return NULL;
    }
    
    if (srt_listen(listen_sock, 5) == SRT_ERROR) {
        av_log(NULL, AV_LOG_ERROR, "[SRT Multi] Failed to listen on port %d: %s\n",
               source->relay_output_port, srt_getlasterror_str());
        return NULL;
    }
    
    av_log(NULL, AV_LOG_INFO, "[SRT Multi] Relay accepting clients on port %d\n",
           source->relay_output_port);
    
    while (source->running) {
        struct sockaddr_in client_addr;
        int addr_len = sizeof(client_addr);
        
        SRTSOCKET client_sock = srt_accept(listen_sock, (struct sockaddr*)&client_addr, &addr_len);
        if (client_sock == SRT_INVALID_SOCK) {
            if (source->running)
                av_log(NULL, AV_LOG_WARNING, "[SRT Multi] Client accept failed on port %d\n",
                       source->relay_output_port);
            continue;
        }
        
        // Find free slot
        int slot = -1;
        for (int i = 0; i < MAX_CLIENTS; i++) {
            pthread_mutex_lock(&source->clients[i].mutex);
            if (!source->clients[i].active) {
                source->clients[i].socket = client_sock;
                source->clients[i].active = 1;
                slot = i;
                pthread_mutex_unlock(&source->clients[i].mutex);
                break;
            }
            pthread_mutex_unlock(&source->clients[i].mutex);
        }
        
        if (slot >= 0) {
            av_log(NULL, AV_LOG_INFO, "[SRT Multi] Client connected to relay port %d (slot %d)\n",
                   source->relay_output_port, slot);
        } else {
            av_log(NULL, AV_LOG_WARNING, "[SRT Multi] No free slots on port %d\n",
                   source->relay_output_port);
            srt_close(client_sock);
        }
    }
    
    srt_close(listen_sock);
    return NULL;
}

static int srtmlti_read_header(AVFormatContext *s)
{
    SRTMultiContext *c = s->priv_data;
    char *sources_copy, *source_url, *saveptr;
    int i;
    
    if (!c->sources_str || !*c->sources_str) {
        av_log(s, AV_LOG_ERROR, "[SRT Multi] No sources provided\n");
        return AVERROR(EINVAL);
    }
    
    // Initialize SRT
    if (srt_startup() < 0) {
        av_log(s, AV_LOG_ERROR, "[SRT Multi] SRT initialization failed\n");
        return AVERROR_EXTERNAL;
    }
    
    // Parse sources
    sources_copy = av_strdup(c->sources_str);
    source_url = av_strtok(sources_copy, ",", &saveptr);
    c->num_sources = 0;
    c->base_relay_port = 19000;  // Start relay ports at 19000
    
    while (source_url && c->num_sources < MAX_SOURCES) {
        SRTSource *source = &c->sources[c->num_sources];
        source->url = av_strdup(source_url);
        source->relay_input_port = c->base_relay_port + (c->num_sources * 2);
        source->relay_output_port = c->base_relay_port + (c->num_sources * 2) + 1;
        source->running = 1;
        source->input_socket = SRT_INVALID_SOCK;
        
        // Initialize client slots
        for (i = 0; i < MAX_CLIENTS; i++) {
            source->clients[i].active = 0;
            pthread_mutex_init(&source->clients[i].mutex, NULL);
        }
        
        // Start relay threads
        pthread_create(&source->input_thread, NULL, srt_input_thread, source);
        pthread_create(&source->output_thread, NULL, srt_output_thread, source);
        
        av_log(s, AV_LOG_INFO, "[SRT Multi] Started relay for source %d: %s (input:%d, output:%d)\n",
               c->num_sources, source->url, source->relay_input_port, source->relay_output_port);
        
        c->num_sources++;
        source_url = av_strtok(NULL, ",", &saveptr);
    }
    
    av_freep(&sources_copy);
    
    if (c->num_sources == 0) {
        av_log(s, AV_LOG_ERROR, "[SRT Multi] No valid sources found\n");
        return AVERROR(EINVAL);
    }
    
    av_log(s, AV_LOG_INFO, "[SRT Multi] Initialized %d sources with internal relay\n", c->num_sources);
    av_log(s, AV_LOG_INFO, "[SRT Multi] Sources should publish to ports %d, %d, %d...\n",
           c->sources[0].relay_input_port,
           c->num_sources > 1 ? c->sources[1].relay_input_port : 0,
           c->num_sources > 2 ? c->sources[2].relay_input_port : 0);
    av_log(s, AV_LOG_INFO, "[SRT Multi] Clients should connect to ports %d, %d, %d...\n",
           c->sources[0].relay_output_port,
           c->num_sources > 1 ? c->sources[1].relay_output_port : 0,
           c->num_sources > 2 ? c->sources[2].relay_output_port : 0);
    
    // For now, just return - actual demuxing would need more implementation
    // This is a skeleton showing the architecture
    return 0;
}

static int srtmlti_read_packet(AVFormatContext *s, AVPacket *pkt)
{
    // This would read from the relay outputs
    // For now, return EOF
    return AVERROR_EOF;
}

static int srtmlti_read_close(AVFormatContext *s)
{
    SRTMultiContext *c = s->priv_data;
    
    // Stop all relays
    for (int i = 0; i < c->num_sources; i++) {
        SRTSource *source = &c->sources[i];
        source->running = 0;
        
        // Close all client connections
        for (int j = 0; j < MAX_CLIENTS; j++) {
            if (source->clients[j].active) {
                srt_close(source->clients[j].socket);
            }
            pthread_mutex_destroy(&source->clients[j].mutex);
        }
        
        pthread_join(source->input_thread, NULL);
        pthread_join(source->output_thread, NULL);
        
        av_freep(&source->url);
    }
    
    srt_cleanup();
    return 0;
}

#define OFFSET(x) offsetof(SRTMultiContext, x)
#define DEC AV_OPT_FLAG_DECODING_PARAM

static const AVOption srtmlti_options[] = {
    { "sources", "Comma-separated list of SRT source URLs", OFFSET(sources_str), AV_OPT_TYPE_STRING, {.str = NULL}, 0, 0, DEC },
    { NULL }
};

static const AVClass srtmlti_class = {
    .class_name = "srt-multi demuxer",
    .item_name  = av_default_item_name,
    .option     = srtmlti_options,
    .version    = LIBAVUTIL_VERSION_INT,
};

const FFInputFormat ff_srtmlti_demuxer = {
    .p.name         = "srt-multi",
    .p.long_name    = NULL_IF_CONFIG_SMALL("SRT Multi-Input with built-in relay"),
    .p.flags        = AVFMT_NOFILE,
    .p.priv_class   = &srtmlti_class,
    .priv_data_size = sizeof(SRTMultiContext),
    .read_header    = srtmlti_read_header,
    .read_packet    = srtmlti_read_packet,
    .read_close     = srtmlti_read_close,
};

#else
// Stub when SRT is not available
const FFInputFormat ff_srtmlti_demuxer = {
    .p.name         = "srt-multi",
    .p.long_name    = NULL_IF_CONFIG_SMALL("SRT Multi-Input (not available - compile with --enable-libsrt)"),
};
#endif
