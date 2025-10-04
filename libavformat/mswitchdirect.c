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
#define PACKET_BUFFER_SIZE 90  // ~3 seconds at 30fps to cover 2s GOP + buffer for I-frame switching
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
    int64_t last_packet_time;      // Last time a packet was received from UDP (reader thread)
    int64_t last_consumption_time; // Last time a packet was consumed from buffer (read_packet)
    int64_t packets_read;          // Total packets read from this source
    int is_healthy;                // Current health status
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
    
    // Switching control
    int pending_switch_to;         // -1 = no pending switch, >= 0 = target source
    int wait_for_iframe;           // Wait for I-frame before switching
    int64_t pending_switch_time;   // When the pending switch was initiated
    int last_active_source;        // Track source changes
    int64_t last_manual_switch_time;  // Time of last manual switch for grace period
    
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

// Non-blocking version for checking if packets are available
static int packet_buffer_try_get(PacketBuffer *buf, AVPacket *pkt)
{
    pthread_mutex_lock(&buf->mutex);
    
    // Don't wait, just check if buffer has packets
    if (buf->count == 0) {
        pthread_mutex_unlock(&buf->mutex);
        return AVERROR(EAGAIN);  // No packets available
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
                // No data available - do NOT update last_packet_time
                // This allows health monitoring to detect source loss
                av_usleep(10000); // 10ms
                av_packet_unref(pkt);
                continue;
            }
            break;
        }
        
        // Update health stats ONLY on successful read - track when UDP is actively receiving
        source->last_packet_time = av_gettime() / 1000; // Convert to milliseconds
        source->packets_read++;
        
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
        
        // Get active source index
        pthread_mutex_lock(&ctx->state_mutex);
        int active = ctx->active_source_index;
        pthread_mutex_unlock(&ctx->state_mutex);
        
        // Check health of all sources (except last source which is black interim)
        int black_source = ctx->num_sources - 1;
        for (i = 0; i < ctx->num_sources; i++) {
            MSwitchSource *src = &ctx->sources[i];
            int is_source_healthy;
            
            // Skip health checks for black interim source (last source)
            if (i == black_source) {
                src->is_healthy = 1;  // Black file is always healthy
                continue;
            }
            
            if (i == active) {
                // Active source: check consumption time
                // Check if we're within manual switch grace period (3 seconds)
                int64_t time_since_manual_switch = current_time - ctx->last_manual_switch_time;
                if (time_since_manual_switch < 3000) {
                    // Within grace period after manual switch - consider healthy
                    is_source_healthy = 1;
                } else if (src->packets_read == 0) {
                    // Active source hasn't received any packets yet
                    if (time_since_startup >= ctx->startup_grace_period_ms + ctx->source_timeout_ms) {
                        is_source_healthy = 0;
                    } else {
                        is_source_healthy = 1;  // Still in grace period
                    }
                } else if (src->last_packet_time == 0) {
                    // Active source received packets but consumption time not initialized (shouldn't happen)
                    is_source_healthy = 1;
                } else {
                    // Check time since last consumption
                    int64_t time_since_packet = current_time - src->last_packet_time;
                    is_source_healthy = (time_since_packet <= ctx->source_timeout_ms);
                }
                
                // Update health status and log changes
                if (!is_source_healthy && src->is_healthy) {
                    src->is_healthy = 0;
                    if (src->packets_read == 0) {
                        av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct Health] Source %d (ACTIVE) unhealthy (never received packets)\n", i);
                    } else {
                        int64_t time_since_packet = current_time - src->last_packet_time;
                        av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct Health] Source %d (ACTIVE) unhealthy (no data for %lldms)\n",
                               i, time_since_packet);
                    }
                } else if (is_source_healthy && !src->is_healthy) {
                    src->is_healthy = 1;
                    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct Health] Source %d (ACTIVE) recovered\n", i);
                }
            } else {
                // Inactive source: just check if buffer has packets (ready for failover)
                pthread_mutex_lock(&src->buffer.mutex);
                int buffer_count = src->buffer.count;
                pthread_mutex_unlock(&src->buffer.mutex);
                
                is_source_healthy = (buffer_count > 0);
                
                // Update health status and log changes
                if (!is_source_healthy && src->is_healthy) {
                    src->is_healthy = 0;
                    av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct Health] Source %d (inactive) unhealthy (buffer empty)\n", i);
                } else if (is_source_healthy && !src->is_healthy) {
                    src->is_healthy = 1;
                    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct Health] Source %d (inactive) recovered\n", i);
                }
            }
        }
        
        // Check if active source is unhealthy (we already have 'active' from above)
        if (!ctx->sources[active].is_healthy) {
            // Determine failover target based on two-stage strategy:
            // 1. If active is NOT black file (last source) → failover to black file
            // 2. If active IS black file → failover to best healthy non-black source
            int black_source = ctx->num_sources - 1;  // Last source is black file
            best_source = -1;
            
            if (active != black_source) {
                // Stage 1: Primary/backup source failed → switch to black interim
                best_source = black_source;
                av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct Health] Primary source %d unhealthy, switching to black interim (source %d)\n",
                       active, best_source);
            } else {
                // Stage 2: We're on black file, look for healthy real sources
                for (i = 0; i < ctx->num_sources - 1; i++) {  // Exclude last source (black file)
                    if (ctx->sources[i].is_healthy) {
                        best_source = i;
                        av_log(NULL, AV_LOG_INFO, "[MSwitch Direct Health] Found healthy source %d, switching from black interim\n", i);
                        break;
                    }
                }
            }
            
            if (best_source >= 0) {
                // Set pending switch - actual switch happens in read_packet at I-frame
                pthread_mutex_lock(&ctx->state_mutex);
                if (ctx->pending_switch_to < 0) {  // No pending switch already
                    ctx->pending_switch_to = best_source;
                    ctx->wait_for_iframe = 1;
                    ctx->pending_switch_time = av_gettime() / 1000;  // Record when switch was initiated
                    av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct Health] 🔄 AUTO-FAILOVER pending: Source %d → %d (waiting for I-frame)\n",
                           active, best_source);
                }
                pthread_mutex_unlock(&ctx->state_mutex);
            } else {
                // No healthy sources and we're on black file - stay on black
                if (active == black_source) {
                    av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Health] No healthy sources, staying on black interim\n");
                }
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
        
        // Set timeout for UDP sources (in microseconds) and disable DTS checks
        AVDictionary *opts = NULL;
        av_dict_set(&opts, "timeout", "100000", 0);  // 100ms timeout for fast failure detection
        
        // Open input
        ret = avformat_open_input(&source->fmt_ctx, source_url, NULL, &opts);
        av_dict_free(&opts);
        if (ret < 0) {
            av_log(s, AV_LOG_ERROR, "[MSwitch Direct] Failed to open source %d: %s\n", ctx->num_sources, av_err2str(ret));
            av_freep(&sources_copy);
            return ret;
        }
        
        // Disable DTS checking to avoid "out of order" warnings when switching sources
        source->fmt_ctx->flags |= AVFMT_FLAG_IGNDTS;
        
        ret = avformat_find_stream_info(source->fmt_ctx, NULL);
        if (ret < 0) {
            av_log(s, AV_LOG_ERROR, "[MSwitch Direct] Failed to find stream info for source %d\n", ctx->num_sources);
            av_freep(&sources_copy);
            return ret;
        }
        
        // Initialize buffer and health stats
        packet_buffer_init(&source->buffer);
        source->last_packet_time = 0; // Will be set when first packet arrives
        source->last_consumption_time = 0; // Will be set when first packet consumed
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
    
    // Initialize switching control
    ctx->pending_switch_to = -1;
    ctx->wait_for_iframe = 0;
    ctx->last_active_source = 0;
    ctx->last_manual_switch_time = 0;
    
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
    int pending_switch;
    int is_keyframe;
    
    pthread_mutex_lock(&ctx->state_mutex);
    active_source = ctx->active_source_index;
    pending_switch = ctx->pending_switch_to;
    pthread_mutex_unlock(&ctx->state_mutex);
    
    // If there's a pending switch, try to read from the new source
    if (pending_switch >= 0) {
        // Try to get a packet from the pending source (non-blocking)
        ret = packet_buffer_try_get(&ctx->sources[pending_switch].buffer, pkt);
        if (ret < 0) {
            // Pending source has no packets, try current source (also non-blocking to avoid deadlock)
            av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Pending source %d has no packets (%s), trying source %d\n",
                   pending_switch, av_err2str(ret), active_source);
            ret = packet_buffer_try_get(&ctx->sources[active_source].buffer, pkt);
            if (ret < 0) {
                // Active source is empty and we have a pending switch - force switch now!
                av_log(s, AV_LOG_WARNING, "[MSwitch Direct] Active source %d empty, forcing switch to %d\n", 
                       active_source, pending_switch);
                
                // Force switch by clearing wait_for_iframe
                pthread_mutex_lock(&ctx->state_mutex);
                ctx->wait_for_iframe = 0;
                pthread_mutex_unlock(&ctx->state_mutex);
                
                // Try again to get packet from pending source, this time blocking
                ret = packet_buffer_get(&ctx->sources[pending_switch].buffer, pkt);
                if (ret < 0) {
                    return ret;
                }
                
                // Execute the forced switch - check if packet is a keyframe first
                is_keyframe = (pkt->flags & AV_PKT_FLAG_KEY);
                
                if (!is_keyframe) {
                    // Not a keyframe - discard and keep waiting
                    av_log(s, AV_LOG_WARNING, "[MSwitch Direct] Forced switch to non-keyframe packet, discarding and waiting for I-frame\n");
                    av_packet_unref(pkt);
                    // Don't reset pending switch, keep waiting for I-frame
                    return AVERROR(EAGAIN);
                }
                
                // We have an I-frame, execute the switch
                pthread_mutex_lock(&ctx->state_mutex);
                ctx->active_source_index = pending_switch;
                ctx->pending_switch_to = -1;
                ctx->wait_for_iframe = 0;
                ctx->first_packet = 1;
                ctx->last_output_pts = AV_NOPTS_VALUE;
                ctx->last_output_dts = AV_NOPTS_VALUE;
                ctx->ts_offset[pending_switch] = 0;
                pthread_mutex_unlock(&ctx->state_mutex);
                
                av_log(s, AV_LOG_WARNING, "[MSwitch Direct] ✅ SWITCHED: Source %d → %d (FORCED on I-frame)\n",
                       active_source, pending_switch);
                
                active_source = pending_switch;
                // Don't return here, continue to timestamp normalization below
            }
        } else {
            // Check if this is an I-frame (keyframe)
            is_keyframe = (pkt->flags & AV_PKT_FLAG_KEY);
            
            // If no keyframe flag, check H.264 NAL units manually for IDR frames
            if (!is_keyframe && pkt->size > 4) {
                const uint8_t *data = pkt->data;
                int size = pkt->size;
                // Check for NAL unit type 5 (IDR) or 7/8 (SPS/PPS which indicate keyframe)
                for (int i = 0; i < size - 4; i++) {
                    if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
                        int nal_type = data[i+3] & 0x1F;
                        if (nal_type == 5 || nal_type == 7 || nal_type == 8) {
                            is_keyframe = 1;
                            av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Detected H.264 keyframe NAL type %d in packet\n", nal_type);
                            break;
                        }
                    } else if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1 && i+4 < size) {
                        int nal_type = data[i+4] & 0x1F;
                        if (nal_type == 5 || nal_type == 7 || nal_type == 8) {
                            is_keyframe = 1;
                            av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Detected H.264 keyframe NAL type %d in packet (4-byte start)\n", nal_type);
                            break;
                        }
                    }
                }
            }
            
            // Log packet info for debugging
            static int packet_count = 0;
            if (packet_count < 20) {  // Log first 20 packets from pending source
                av_log(s, AV_LOG_INFO, "[MSwitch Direct] Pending source %d packet: flags=0x%x, is_keyframe=%d\n",
                       pending_switch, pkt->flags, is_keyframe);
                packet_count++;
            }
            
            // Check if we should force switch due to timeout
            int64_t current_time = av_gettime() / 1000;
            int64_t time_waiting = current_time - ctx->pending_switch_time;
            int force_switch = (time_waiting > 3000);  // Force after 3 seconds
            
            if (is_keyframe || !ctx->wait_for_iframe || force_switch) {
                // Execute the switch
                pthread_mutex_lock(&ctx->state_mutex);
                ctx->active_source_index = pending_switch;
                ctx->pending_switch_to = -1;
                ctx->wait_for_iframe = 0;
                
                // Reset timestamp tracking for new source
                ctx->first_packet = 1;
                ctx->last_output_pts = AV_NOPTS_VALUE;
                ctx->last_output_dts = AV_NOPTS_VALUE;
                ctx->ts_offset[pending_switch] = 0;
                
                pthread_mutex_unlock(&ctx->state_mutex);
                
                const char *reason = is_keyframe ? "(I-frame)" : force_switch ? "(timeout)" : "(forced)";
                av_log(s, AV_LOG_WARNING, "[MSwitch Direct] ✅ SWITCHED: Source %d → %d %s (flags=0x%x, waited=%lldms)\n",
                       active_source, pending_switch, reason, pkt->flags, time_waiting);
                
                active_source = pending_switch;
            } else {
                // Not an I-frame yet, discard and keep waiting
                av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Discarding non-keyframe from source %d (flags=0x%x)\n",
                       pending_switch, pkt->flags);
                av_packet_unref(pkt);
                
                // Fall back to current source for this packet
                ret = packet_buffer_get(&ctx->sources[active_source].buffer, pkt);
                if (ret < 0) {
                    // Current source is also EOF, wait for I-frame or timeout
                    if (ret == AVERROR_EOF && ctx->auto_failover_enabled) {
                        av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Active source EOF while waiting for I-frame, retrying...\n");
                        av_usleep(10000);  // Sleep 10ms
                        return AVERROR(EAGAIN);  // Retry
                    }
                    return ret;
                }
            }
        }
    } else {
        // No pending switch, normal operation
        ret = packet_buffer_get(&ctx->sources[active_source].buffer, pkt);
        if (ret < 0) {
            // If auto-failover is enabled, trigger immediate failover
            // But give manual switches a 3-second grace period to buffer
            if (ret == AVERROR_EOF && ctx->auto_failover_enabled) {
                int64_t current_time = av_gettime() / 1000;
                int64_t time_since_manual_switch = current_time - ctx->last_manual_switch_time;
                
                if (time_since_manual_switch < 3000) {
                    // Within grace period after manual switch - allow buffering
                    av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Manual switch grace period (%lldms), waiting for buffer...\n",
                           time_since_manual_switch);
                    av_usleep(100000);  // Sleep 100ms
                    return AVERROR(EAGAIN);
                }
                
                av_log(s, AV_LOG_WARNING, "[MSwitch Direct] Active source %d EOF, triggering immediate failover\n", active_source);
                
                // Two-stage failover strategy:
                // 1. If active is NOT black file (last source) → failover to black file
                // 2. If active IS black file → failover to best healthy non-black source
                int black_source = ctx->num_sources - 1;  // Last source is black file
                int best_source = -1;
                
                if (active_source != black_source) {
                    // Stage 1: Primary/backup source failed → switch to black interim
                    best_source = black_source;
                    av_log(s, AV_LOG_WARNING, "[MSwitch Direct] Switching to black interim (source %d)\n", best_source);
                } else {
                    // Stage 2: We're on black file, look for healthy real sources
                    for (int i = 0; i < ctx->num_sources - 1; i++) {  // Exclude last source (black file)
                        if (ctx->sources[i].is_healthy) {
                            best_source = i;
                            av_log(s, AV_LOG_INFO, "[MSwitch Direct] Found healthy source %d, switching from black interim\n", i);
                            break;
                        }
                    }
                }
                
                if (best_source >= 0) {
                    // Set pending switch
                    pthread_mutex_lock(&ctx->state_mutex);
                    if (ctx->pending_switch_to < 0) {  // No pending switch already
                        ctx->pending_switch_to = best_source;
                        ctx->wait_for_iframe = 1;
                        ctx->pending_switch_time = av_gettime() / 1000;
                        pthread_mutex_unlock(&ctx->state_mutex);
                        av_log(s, AV_LOG_WARNING, "[MSwitch Direct] 🔄 IMMEDIATE FAILOVER: Source %d → %d\n",
                               active_source, best_source);
                        // Retry read_packet, which will now hit the pending_switch path
                        return AVERROR(EAGAIN);
                    }
                    pthread_mutex_unlock(&ctx->state_mutex);
                } else {
                    // No healthy sources - stay on black if that's where we are
                    if (active_source == black_source) {
                        av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] No healthy sources, staying on black interim\n");
                    }
                    av_usleep(100000);  // Sleep 100ms before retry
                    return AVERROR(EAGAIN);  // Keep trying
                }
            }
            return ret;
        }
    }
    
    // Update consumption time for health monitoring
    ctx->sources[active_source].last_consumption_time = av_gettime() / 1000;  // milliseconds
    
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
    global_mswitchdirect_ctx->last_manual_switch_time = av_gettime() / 1000;  // Record manual switch time
    pthread_mutex_unlock(&global_mswitchdirect_ctx->state_mutex);
    
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct CLI] ⚡ Switched from source %d to %d (manual)\n",
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
    { "msw_grace_period", "Startup grace period in milliseconds before health checks begin", OFFSET(startup_grace_period_ms), AV_OPT_TYPE_INT, {.i64 = 0}, 0, 60000, DEC },
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

