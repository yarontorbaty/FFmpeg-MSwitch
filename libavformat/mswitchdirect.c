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
    
    // Health monitoring
    int64_t last_packet_time;  // Last time a packet was successfully read
    int64_t packets_read;      // Total packets read from this source
    int is_healthy;            // Current health status
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
    
    // Timestamp normalization
    int64_t last_output_pts;
    int64_t last_output_dts;
    int64_t ts_offset[MAX_SOURCES];  // Offset to add to each source
    int first_packet;
    
    // Health monitoring and auto-failover
    int auto_failover_enabled;
    int health_check_interval_ms;  // How often to check health
    int source_timeout_ms;         // How long before source is unhealthy
    int startup_grace_period_ms;   // Grace period after startup before health checks
    int64_t startup_time;          // Time when demuxer was initialized
    pthread_t health_thread;
    int health_running;
    int64_t last_health_check;
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
        
        // Update health stats
        source->last_packet_time = av_gettime() / 1000; // Convert to milliseconds
        source->packets_read++;
        source->is_healthy = 1;
        
        // Log first packet
        if (source->packets_read == 1) {
            av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] Source %d received first packet\n", source->source_index);
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

// Health monitoring thread - checks source health and performs auto-failover
static void *health_monitor_thread(void *arg)
{
    MSwitchDirectContext *ctx = (MSwitchDirectContext *)arg;
    int64_t current_time;
    int i, best_source;
    
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct Health] Starting health monitor (timeout: %dms, check interval: %dms, grace period: %dms)\n",
           ctx->source_timeout_ms, ctx->health_check_interval_ms, ctx->startup_grace_period_ms);
    
    while (ctx->health_running) {
        av_usleep(ctx->health_check_interval_ms * 1000); // Convert to microseconds
        
        if (!ctx->auto_failover_enabled) {
            continue;
        }
        
        current_time = av_gettime() / 1000; // milliseconds
        
        // Check if we're still in startup grace period
        int64_t time_since_startup = current_time - ctx->startup_time;
        if (time_since_startup < ctx->startup_grace_period_ms) {
            // During grace period, don't mark sources unhealthy
            av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Health] In grace period (%lld/%dms), skipping health checks\n",
                   time_since_startup, ctx->startup_grace_period_ms);
            continue;
        }
        
        // Check health of all sources
        for (i = 0; i < ctx->num_sources; i++) {
            MSwitchSource *src = &ctx->sources[i];
            
            // Only check health if source has received at least one packet
            if (src->packets_read == 0) {
                // Source hasn't received any packets yet
                // Keep it healthy during grace period, mark unhealthy after
                if (time_since_startup >= ctx->startup_grace_period_ms + ctx->source_timeout_ms) {
                    if (src->is_healthy) {
                        src->is_healthy = 0;
                        av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct Health] Source %d unhealthy (never received packets)\n", i);
                    }
                }
                continue;
            }
            
            int64_t time_since_packet = current_time - src->last_packet_time;
            
            // Check buffer status - if buffer has packets, source is actively receiving
            pthread_mutex_lock(&src->buffer.mutex);
            int buffer_count = src->buffer.count;
            pthread_mutex_unlock(&src->buffer.mutex);
            
            // Source is healthy if either:
            // 1. Recently received a packet (within timeout)
            // 2. Buffer has packets (reader thread is actively working)
            int is_source_healthy = (time_since_packet <= ctx->source_timeout_ms) || (buffer_count > 0);
            
            if (!is_source_healthy) {
                if (src->is_healthy) {
                    src->is_healthy = 0;
                    av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct Health] Source %d unhealthy (no data for %lldms, buffer empty)\n",
                           i, time_since_packet);
                }
            } else {
                if (!src->is_healthy) {
                    src->is_healthy = 1;
                    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct Health] Source %d recovered\n", i);
                }
            }
        }
        
        // Check if active source is unhealthy
        pthread_mutex_lock(&ctx->state_mutex);
        int active = ctx->active_source_index;
        pthread_mutex_unlock(&ctx->state_mutex);
        
        if (!ctx->sources[active].is_healthy) {
            // Find best healthy source
            best_source = -1;
            for (i = 0; i < ctx->num_sources; i++) {
                if (i != active && ctx->sources[i].is_healthy) {
                    best_source = i;
                    break;
                }
            }
            
            if (best_source >= 0) {
                pthread_mutex_lock(&ctx->state_mutex);
                ctx->active_source_index = best_source;
                pthread_mutex_unlock(&ctx->state_mutex);
                
                av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct Health] 🔄 AUTO-FAILOVER: Source %d → %d\n",
                       active, best_source);
            } else {
                av_log(NULL, AV_LOG_ERROR, "[MSwitch Direct Health] ⚠️  No healthy sources available!\n");
            }
        }
    }
    
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
        
        // Initialize buffer and health stats
        packet_buffer_init(&source->buffer);
        source->last_packet_time = 0; // Will be set when first packet arrives
        source->packets_read = 0;
        source->is_healthy = 1; // Assume healthy initially
        
        // Start reader thread
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
    
    // Initialize timestamp normalization
    ctx->first_packet = 1;
    ctx->last_output_pts = AV_NOPTS_VALUE;
    ctx->last_output_dts = AV_NOPTS_VALUE;
    for (i = 0; i < MAX_SOURCES; i++) {
        ctx->ts_offset[i] = 0;
    }
    
    // Start health monitoring thread if auto-failover enabled
    if (ctx->auto_failover_enabled) {
        ctx->health_running = 1;
        ctx->startup_time = av_gettime() / 1000;  // Record startup time
        ctx->last_health_check = ctx->startup_time;
        pthread_create(&ctx->health_thread, NULL, health_monitor_thread, ctx);
        av_log(s, AV_LOG_INFO, "[MSwitch Direct] Auto-failover enabled (timeout: %dms, check interval: %dms, grace period: %dms)\n",
               ctx->source_timeout_ms, ctx->health_check_interval_ms, ctx->startup_grace_period_ms);
    } else {
        ctx->health_running = 0;
        av_log(s, AV_LOG_INFO, "[MSwitch Direct] Auto-failover disabled\n");
    }
    
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
    int ret;
    
    pthread_mutex_lock(&ctx->state_mutex);
    active_source = ctx->active_source_index;
    pthread_mutex_unlock(&ctx->state_mutex);
    
    // Read from active source's buffer
    ret = packet_buffer_get(&ctx->sources[active_source].buffer, pkt);
    if (ret < 0) {
        return ret;
    }
    
    // Normalize timestamps to ensure continuity across switches
    if (ctx->first_packet) {
        // First packet ever - set baseline
        ctx->first_packet = 0;
        if (pkt->pts != AV_NOPTS_VALUE) {
            ctx->last_output_pts = pkt->pts;
        }
        if (pkt->dts != AV_NOPTS_VALUE) {
            ctx->last_output_dts = pkt->dts;
        }
    } else {
        // Check if we need to adjust timestamps for this source
        int64_t expected_dts = ctx->last_output_dts;
        int64_t actual_dts = (pkt->dts != AV_NOPTS_VALUE) ? pkt->dts : pkt->pts;
        
        if (actual_dts != AV_NOPTS_VALUE && expected_dts != AV_NOPTS_VALUE) {
            // Calculate required offset to make timestamps continuous
            int64_t required_offset = expected_dts - actual_dts;
            
            // If offset is significantly different, we just switched sources
            if (llabs(required_offset - ctx->ts_offset[active_source]) > 90000) { // ~1 second
                ctx->ts_offset[active_source] = required_offset;
                av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Adjusting source %d timestamp offset to %lld\n",
                       active_source, ctx->ts_offset[active_source]);
            }
        }
        
        // Apply offset
        if (pkt->pts != AV_NOPTS_VALUE) {
            pkt->pts += ctx->ts_offset[active_source];
            ctx->last_output_pts = pkt->pts;
        }
        if (pkt->dts != AV_NOPTS_VALUE) {
            pkt->dts += ctx->ts_offset[active_source];
            ctx->last_output_dts = pkt->dts;
        }
    }
    
    return 0;
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
    
    MSwitchDirectContext *ctx = global_mswitchdirect_ctx;
    
    pthread_mutex_lock(&ctx->state_mutex);
    int active = ctx->active_source_index;
    int total = ctx->num_sources;
    pthread_mutex_unlock(&ctx->state_mutex);
    
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] ════════════════════════════════\n");
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] Active source: %d / %d\n", active, total - 1);
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] Auto-failover: %s\n",
           ctx->auto_failover_enabled ? "ENABLED" : "DISABLED");
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] ────────────────────────────────\n");
    
    // Show detailed status for each source
    int64_t current_time = av_gettime() / 1000;
    for (int i = 0; i < total; i++) {
        MSwitchSource *src = &ctx->sources[i];
        pthread_mutex_lock(&src->buffer.mutex);
        int count = src->buffer.count;
        pthread_mutex_unlock(&src->buffer.mutex);
        
        int64_t time_since_packet = current_time - src->last_packet_time;
        const char *status_icon = src->is_healthy ? "✅" : "❌";
        const char *active_icon = (i == active) ? " [ACTIVE]" : "";
        
        av_log(NULL, AV_LOG_INFO, "[MSwitch Direct]   Source %d: %s %s%s\n",
               i, status_icon, src->is_healthy ? "HEALTHY" : "UNHEALTHY", active_icon);
        av_log(NULL, AV_LOG_INFO, "[MSwitch Direct]     Buffer: %d packets | Packets read: %lld | Last packet: %lldms ago\n",
               count, src->packets_read, time_since_packet);
    }
    
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] ════════════════════════════════\n");
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
    
    // Stop health monitoring thread
    ctx->health_running = 0;
    if (ctx->auto_failover_enabled && ctx->health_thread) {
        pthread_join(ctx->health_thread, NULL);
    }
    
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
    { "msw_auto_failover", "Enable automatic failover on source failure", OFFSET(auto_failover_enabled), AV_OPT_TYPE_BOOL, {.i64 = 1}, 0, 1, DEC },
    { "msw_health_interval", "Health check interval in milliseconds", OFFSET(health_check_interval_ms), AV_OPT_TYPE_INT, {.i64 = 2000}, 100, 10000, DEC },
    { "msw_source_timeout", "Source timeout in milliseconds before marked unhealthy", OFFSET(source_timeout_ms), AV_OPT_TYPE_INT, {.i64 = 5000}, 1000, 60000, DEC },
    { "msw_grace_period", "Startup grace period in milliseconds before health checks begin", OFFSET(startup_grace_period_ms), AV_OPT_TYPE_INT, {.i64 = 10000}, 0, 60000, DEC },
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

