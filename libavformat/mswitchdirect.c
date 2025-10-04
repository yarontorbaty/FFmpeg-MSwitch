/*
 * MSwitch Direct demuxer - Direct multi-source switching without subprocesses
 * Copyright (c) 2025
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/**
 * @file
 * MSwitch Direct demuxer
 * 
 * Usage: ffmpeg -i "mswitchdirect://localhost?sources=udp://127.0.0.1:12350,udp://127.0.0.1:12351,udp://127.0.0.1:12352&port=8099" ...
 * 
 * This demuxer opens all sources directly and reads from them concurrently,
 * providing true seamless switching without subprocesses or UDP proxies.
 */

#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>

#include "libavutil/avstring.h"
#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/time.h"
#include "avformat.h"
#include "demux.h"
#include "url.h"

#define MAX_SOURCES 10
#define PACKET_BUFFER_SIZE 100
#define MSW_CONTROL_PORT_DEFAULT 8099

typedef struct PacketBuffer {
    AVPacket *packets[PACKET_BUFFER_SIZE];
    int read_index;
    int write_index;
    int count;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int eof;
} PacketBuffer;

typedef struct MSwitchSource {
    char *url;
    AVFormatContext *fmt_ctx;
    PacketBuffer buffer;
    pthread_t reader_thread;
    int thread_running;
    int source_index;
} MSwitchSource;

typedef struct MSwitchDirectContext {
    const AVClass *class;
    
    int num_sources;
    MSwitchSource sources[MAX_SOURCES];
    int active_source_index;
    pthread_mutex_t state_mutex;
    
    int control_port;
    int control_socket;
    pthread_t control_thread;
    int control_running;
    
    char *sources_str;  // Comma-separated source URLs
} MSwitchDirectContext;

// Global context for CLI control
static MSwitchDirectContext *global_mswitchdirect_ctx = NULL;

// Forward declarations for CLI control functions (defined in mswitchdirect.h)
int mswitchdirect_cli_switch(int source_index);
void mswitchdirect_cli_status(void);

// Packet buffer functions
static void packet_buffer_init(PacketBuffer *buf)
{
    memset(buf, 0, sizeof(*buf));
    pthread_mutex_init(&buf->mutex, NULL);
    pthread_cond_init(&buf->cond, NULL);
}

static void packet_buffer_destroy(PacketBuffer *buf)
{
    pthread_mutex_lock(&buf->mutex);
    for (int i = 0; i < buf->count; i++) {
        int idx = (buf->read_index + i) % PACKET_BUFFER_SIZE;
        if (buf->packets[idx]) {
            av_packet_free(&buf->packets[idx]);
        }
    }
    pthread_mutex_unlock(&buf->mutex);
    pthread_mutex_destroy(&buf->mutex);
    pthread_cond_destroy(&buf->cond);
}

static int packet_buffer_put(PacketBuffer *buf, AVPacket *pkt)
{
    pthread_mutex_lock(&buf->mutex);
    
    // Wait if buffer is full
    while (buf->count >= PACKET_BUFFER_SIZE && !buf->eof) {
        pthread_cond_wait(&buf->cond, &buf->mutex);
    }
    
    if (buf->eof) {
        pthread_mutex_unlock(&buf->mutex);
        return -1;
    }
    
    // Allocate and copy packet
    buf->packets[buf->write_index] = av_packet_clone(pkt);
    buf->write_index = (buf->write_index + 1) % PACKET_BUFFER_SIZE;
    buf->count++;
    
    pthread_cond_signal(&buf->cond);
    pthread_mutex_unlock(&buf->mutex);
    
    return 0;
}

static int packet_buffer_get(PacketBuffer *buf, AVPacket *pkt)
{
    pthread_mutex_lock(&buf->mutex);
    
    // Wait if buffer is empty
    while (buf->count == 0 && !buf->eof) {
        pthread_cond_wait(&buf->cond, &buf->mutex);
    }
    
    if (buf->count == 0 && buf->eof) {
        pthread_mutex_unlock(&buf->mutex);
        return AVERROR_EOF;
    }
    
    // Move packet from buffer
    av_packet_move_ref(pkt, buf->packets[buf->read_index]);
    av_packet_free(&buf->packets[buf->read_index]);
    buf->read_index = (buf->read_index + 1) % PACKET_BUFFER_SIZE;
    buf->count--;
    
    pthread_cond_signal(&buf->cond);
    pthread_mutex_unlock(&buf->mutex);
    
    return 0;
}

// Reader thread - continuously reads from a source into its buffer
static void *source_reader_thread(void *arg)
{
    MSwitchSource *source = (MSwitchSource *)arg;
    AVPacket *pkt = av_packet_alloc();
    int ret;
    
    while (source->thread_running) {
        ret = av_read_frame(source->fmt_ctx, pkt);
        if (ret < 0) {
            if (ret == AVERROR_EOF || ret == AVERROR(EAGAIN)) {
                // Restart or continue
                av_usleep(10000); // 10ms
                av_packet_unref(pkt);
                continue;
            }
            break;
        }
        
        // Put packet in buffer
        if (packet_buffer_put(&source->buffer, pkt) < 0) {
            break;
        }
        
        av_packet_unref(pkt);
    }
    
    av_packet_free(&pkt);
    pthread_mutex_lock(&source->buffer.mutex);
    source->buffer.eof = 1;
    pthread_cond_broadcast(&source->buffer.cond);
    pthread_mutex_unlock(&source->buffer.mutex);
    
    return NULL;
}

// Control thread - HTTP server for switching commands
static void *control_server_thread(void *arg)
{
    MSwitchDirectContext *ctx = (MSwitchDirectContext *)arg;
    struct sockaddr_in client_addr;
    socklen_t client_len = sizeof(client_addr);
    char buffer[4096];
    char response[1024];
    
    while (ctx->control_running) {
        fd_set readfds;
        struct timeval tv = {.tv_sec = 1, .tv_usec = 0};
        
        FD_ZERO(&readfds);
        FD_SET(ctx->control_socket, &readfds);
        
        int ret = select(ctx->control_socket + 1, &readfds, NULL, NULL, &tv);
        if (ret <= 0) continue;
        
        int client_socket = accept(ctx->control_socket, (struct sockaddr *)&client_addr, &client_len);
        if (client_socket < 0) continue;
        
        ssize_t bytes_read = read(client_socket, buffer, sizeof(buffer) - 1);
        if (bytes_read > 0) {
            buffer[bytes_read] = '\0';
            
            // Parse /switch/N or /switch?source=N
            int new_source = -1;
            char *switch_path = strstr(buffer, "POST /switch/");
            if (!switch_path) {
                switch_path = strstr(buffer, "GET /switch/");
            }
            
            if (switch_path) {
                char *path_start = strchr(switch_path, '/');
                if (path_start) {
                    path_start += 8; // Skip "/switch/"
                    new_source = atoi(path_start);
                }
            }
            
            if (new_source >= 0 && new_source < ctx->num_sources) {
                pthread_mutex_lock(&ctx->state_mutex);
                ctx->active_source_index = new_source;
                pthread_mutex_unlock(&ctx->state_mutex);
                
                snprintf(response, sizeof(response),
                         "HTTP/1.1 200 OK\r\n"
                         "Content-Type: application/json\r\n"
                         "Content-Length: 25\r\n"
                         "\r\n"
                         "{\"status\":\"ok\",\"source\":\"%d\"}", new_source);
            } else {
                snprintf(response, sizeof(response),
                         "HTTP/1.1 400 Bad Request\r\n"
                         "Content-Type: application/json\r\n"
                         "Content-Length: 31\r\n"
                         "\r\n"
                         "{\"error\":\"invalid source\"}");
            }
        } else {
            snprintf(response, sizeof(response),
                     "HTTP/1.1 400 Bad Request\r\n"
                     "Content-Length: 0\r\n"
                     "\r\n");
        }
        
        send(client_socket, response, strlen(response), 0);
        close(client_socket);
    }
    
    return NULL;
}

static int mswitchdirect_read_header(AVFormatContext *s)
{
    MSwitchDirectContext *ctx = s->priv_data;
    char *sources_copy, *source_url, *saveptr;
    int ret, i;
    
    av_log(s, AV_LOG_INFO, "[MSwitch Direct] Initializing with sources: %s\n", ctx->sources_str);
    
    // Parse sources
    sources_copy = av_strdup(ctx->sources_str);
    if (!sources_copy) {
        return AVERROR(ENOMEM);
    }
    
    ctx->num_sources = 0;
    source_url = av_strtok(sources_copy, ",", &saveptr);
    while (source_url && ctx->num_sources < MAX_SOURCES) {
        MSwitchSource *source = &ctx->sources[ctx->num_sources];
        source->url = av_strdup(source_url);
        source->source_index = ctx->num_sources;
        
        av_log(s, AV_LOG_INFO, "[MSwitch Direct] Opening source %d: %s\n", ctx->num_sources, source_url);
        
        // Open input
        ret = avformat_open_input(&source->fmt_ctx, source_url, NULL, NULL);
        if (ret < 0) {
            av_log(s, AV_LOG_ERROR, "[MSwitch Direct] Failed to open source %d: %s\n", ctx->num_sources, av_err2str(ret));
            av_freep(&sources_copy);
            return ret;
        }
        
        ret = avformat_find_stream_info(source->fmt_ctx, NULL);
        if (ret < 0) {
            av_log(s, AV_LOG_ERROR, "[MSwitch Direct] Failed to find stream info for source %d\n", ctx->num_sources);
            av_freep(&sources_copy);
            return ret;
        }
        
        // Initialize buffer and start reader thread
        packet_buffer_init(&source->buffer);
        source->thread_running = 1;
        pthread_create(&source->reader_thread, NULL, source_reader_thread, source);
        
        ctx->num_sources++;
        source_url = av_strtok(NULL, ",", &saveptr);
    }
    
    av_freep(&sources_copy);
    
    if (ctx->num_sources == 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Direct] No sources provided\n");
        return AVERROR(EINVAL);
    }
    
    // Copy streams from first source
    for (i = 0; i < ctx->sources[0].fmt_ctx->nb_streams; i++) {
        AVStream *in_st = ctx->sources[0].fmt_ctx->streams[i];
        AVStream *out_st = avformat_new_stream(s, NULL);
        if (!out_st) {
            return AVERROR(ENOMEM);
        }
        
        ret = avcodec_parameters_copy(out_st->codecpar, in_st->codecpar);
        if (ret < 0) {
            return ret;
        }
        
        out_st->time_base = in_st->time_base;
    }
    
    // Start control server
    ctx->control_socket = socket(AF_INET, SOCK_STREAM, 0);
    if (ctx->control_socket < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Direct] Failed to create control socket\n");
        return AVERROR(errno);
    }
    
    int opt = 1;
    setsockopt(ctx->control_socket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(ctx->control_port);
    
    if (bind(ctx->control_socket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Direct] Failed to bind control socket to port %d\n", ctx->control_port);
        close(ctx->control_socket);
        return AVERROR(errno);
    }
    
    if (listen(ctx->control_socket, 5) < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Direct] Failed to listen on control socket\n");
        close(ctx->control_socket);
        return AVERROR(errno);
    }
    
    ctx->control_running = 1;
    pthread_create(&ctx->control_thread, NULL, control_server_thread, ctx);
    
    pthread_mutex_init(&ctx->state_mutex, NULL);
    ctx->active_source_index = 0;
    
    // Set global context for CLI control
    global_mswitchdirect_ctx = ctx;
    
    av_log(s, AV_LOG_INFO, "[MSwitch Direct] Initialized with %d sources, control port %d\n", 
           ctx->num_sources, ctx->control_port);
    av_log(s, AV_LOG_INFO, "[MSwitch Direct] CLI controls: Press 0-%d to switch sources, 'm' for status\n",
           ctx->num_sources - 1);
    
    return 0;
}

static int mswitchdirect_read_packet(AVFormatContext *s, AVPacket *pkt)
{
    MSwitchDirectContext *ctx = s->priv_data;
    int active_source;
    
    pthread_mutex_lock(&ctx->state_mutex);
    active_source = ctx->active_source_index;
    pthread_mutex_unlock(&ctx->state_mutex);
    
    // Read from active source's buffer
    return packet_buffer_get(&ctx->sources[active_source].buffer, pkt);
}

// CLI control function - called from ffmpeg.c keyboard handler
int mswitchdirect_cli_switch(int source_index)
{
    if (!global_mswitchdirect_ctx) {
        return AVERROR(EINVAL);
    }
    
    if (source_index < 0 || source_index >= global_mswitchdirect_ctx->num_sources) {
        av_log(NULL, AV_LOG_ERROR, "[MSwitch Direct CLI] Invalid source index %d (valid: 0-%d)\n",
               source_index, global_mswitchdirect_ctx->num_sources - 1);
        return AVERROR(EINVAL);
    }
    
    pthread_mutex_lock(&global_mswitchdirect_ctx->state_mutex);
    int old_index = global_mswitchdirect_ctx->active_source_index;
    global_mswitchdirect_ctx->active_source_index = source_index;
    pthread_mutex_unlock(&global_mswitchdirect_ctx->state_mutex);
    
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct CLI] ⚡ Switched from source %d to %d\n",
           old_index, source_index);
    
    return 0;
}

// CLI status function
void mswitchdirect_cli_status(void)
{
    if (!global_mswitchdirect_ctx) {
        av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] No demuxer active\n");
        return;
    }
    
    pthread_mutex_lock(&global_mswitchdirect_ctx->state_mutex);
    int active = global_mswitchdirect_ctx->active_source_index;
    int total = global_mswitchdirect_ctx->num_sources;
    pthread_mutex_unlock(&global_mswitchdirect_ctx->state_mutex);
    
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] Status: Active source = %d, Total sources = %d\n",
           active, total);
    
    // Show buffer status for each source
    for (int i = 0; i < total; i++) {
        MSwitchSource *src = &global_mswitchdirect_ctx->sources[i];
        pthread_mutex_lock(&src->buffer.mutex);
        int count = src->buffer.count;
        pthread_mutex_unlock(&src->buffer.mutex);
        
        av_log(NULL, AV_LOG_INFO, "  Source %d: %d packets buffered %s\n",
               i, count, (i == active) ? "[ACTIVE]" : "");
    }
}

static int mswitchdirect_read_close(AVFormatContext *s)
{
    MSwitchDirectContext *ctx = s->priv_data;
    
    // Clear global context
    if (global_mswitchdirect_ctx == ctx) {
        global_mswitchdirect_ctx = NULL;
    }
    int i;
    
    av_log(s, AV_LOG_INFO, "[MSwitch Direct] Closing\n");
    
    // Stop control thread
    ctx->control_running = 0;
    if (ctx->control_thread) {
        pthread_join(ctx->control_thread, NULL);
    }
    if (ctx->control_socket >= 0) {
        close(ctx->control_socket);
    }
    
    // Stop reader threads and clean up sources
    for (i = 0; i < ctx->num_sources; i++) {
        MSwitchSource *source = &ctx->sources[i];
        source->thread_running = 0;
        pthread_mutex_lock(&source->buffer.mutex);
        source->buffer.eof = 1;
        pthread_cond_broadcast(&source->buffer.cond);
        pthread_mutex_unlock(&source->buffer.mutex);
        
        if (source->reader_thread) {
            pthread_join(source->reader_thread, NULL);
        }
        
        packet_buffer_destroy(&source->buffer);
        
        if (source->fmt_ctx) {
            avformat_close_input(&source->fmt_ctx);
        }
        
        av_freep(&source->url);
    }
    
    pthread_mutex_destroy(&ctx->state_mutex);
    
    return 0;
}

#define OFFSET(x) offsetof(MSwitchDirectContext, x)
#define DEC AV_OPT_FLAG_DECODING_PARAM

static const AVOption mswitchdirect_options[] = {
    { "msw_sources", "Comma-separated list of source URLs", OFFSET(sources_str), AV_OPT_TYPE_STRING, {.str = NULL}, 0, 0, DEC },
    { "msw_port", "Control port for HTTP switching", OFFSET(control_port), AV_OPT_TYPE_INT, {.i64 = MSW_CONTROL_PORT_DEFAULT}, 1024, 65535, DEC },
    { NULL }
};

static const AVClass mswitchdirect_class = {
    .class_name = "mswitchdirect demuxer",
    .item_name  = av_default_item_name,
    .option     = mswitchdirect_options,
    .version    = LIBAVUTIL_VERSION_INT,
};

const FFInputFormat ff_mswitchdirect_demuxer = {
    .p.name         = "mswitchdirect",
    .p.long_name    = NULL_IF_CONFIG_SMALL("MSwitch Direct multi-source demuxer"),
    .p.flags        = AVFMT_NOFILE,
    .p.priv_class   = &mswitchdirect_class,
    .priv_data_size = sizeof(MSwitchDirectContext),
    .read_header    = mswitchdirect_read_header,
    .read_packet    = mswitchdirect_read_packet,
    .read_close     = mswitchdirect_read_close,
};

