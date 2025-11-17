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

#include <fcntl.h>
#include <errno.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <io.h>
#define close closesocket
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#endif

#include "libavutil/avstring.h"
#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/thread.h"
#include "libavutil/time.h"
#include "avformat.h"
#include "demux.h"
#include "url.h"

// SRT support
#ifdef CONFIG_LIBSRT
#include <srt/srt.h>
#define HAVE_SRT 1
#else
#define HAVE_SRT 0
#endif

#define MAX_SOURCES 10
#define PACKET_BUFFER_SIZE 90  // ~3 seconds at 30fps to cover 2s GOP + buffer for I-frame switching
#define MSW_CONTROL_PORT_DEFAULT 8099

typedef struct PacketBuffer {
    AVPacket *packets[PACKET_BUFFER_SIZE];
    int read_index;
    int write_index;
    int count;
    AVMutex mutex;
    AVCond cond;
    int eof;
    int last_iframe_index;  // Index of the last I-frame in the buffer (-1 if none)
    int last_sps_pps_index; // Index where SPS/PPS starts before the I-frame (-1 if none)
    int has_iframe;         // Whether we have at least one I-frame in the buffer
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
    
    // Freeze-frame support
    AVPacket *last_good_packet;    // Last successfully read packet (for freeze-frame on failure)
    int has_good_packet;           // Whether we have a valid last_good_packet
    
    // Reconnection tracking
    int64_t reconnect_start_time;  // When reconnection attempts started (0 = not reconnecting)
    void *parent_ctx;              // Pointer to MSwitchDirectContext for accessing reconnect_timeout_ms
    
    // Cached parameter sets for decoder recovery
    AVPacket *cached_sps;          // Cached SPS packet for this source
    AVPacket *cached_pps;          // Cached PPS packet for this source
    int has_sps;                   // Whether we have cached SPS
    int has_pps;                   // Whether we have cached PPS
} MSwitchSource;

#if HAVE_SRT
// SRT Relay structures for transparent SRT support
#define MAX_SRT_CLIENTS 10
#define SRT_BUFFER_SIZE 2048

typedef struct SRTRelayClient {
    SRTSOCKET socket;
    int active;
    AVMutex mutex;
} SRTRelayClient;

typedef struct SRTRelay {
    int enabled;                    // Whether SRT relay is active
    int input_port;                 // Port where sources publish
    SRTSOCKET input_socket;         // Current input connection
    pthread_t input_thread;         // Thread handling input
    int running;                    // Relay is running
    
    int num_outputs;                // Number of output ports
    int output_ports[MAX_SOURCES];  // Output ports for each source
    pthread_t output_threads[MAX_SOURCES];  // Threads for each output port
    
    SRTRelayClient clients[MAX_SRT_CLIENTS];  // Connected clients
    AVMutex clients_mutex;  // Protect client list
    
    char *original_urls[MAX_SOURCES];  // Original SRT URLs from user
    char *relay_urls[MAX_SOURCES];     // Modified URLs pointing to relay
} SRTRelay;
#endif

typedef struct MSwitchDirectContext {
    const AVClass *class;
    
    int num_sources;
    MSwitchSource sources[MAX_SOURCES];
    int active_source_index;
    AVMutex state_mutex;
    
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
    int freeze_frame_active;       // Currently outputting freeze-frame due to source failure
    int64_t freeze_frame_duration; // Duration of one frame in timebase units (for timestamp increment)
    
    // Decoder restart signaling
    int need_decoder_flush;        // Need to signal decoder flush before next packet
    int need_sps_pps_injection;    // Need to inject SPS/PPS after flush, before I-frame
    AVPacket *pending_first_packet; // First packet after switch (usually I-frame) to output after flush+SPS/PPS
    
    // Health monitoring and auto-failover
    int auto_failover_enabled;
    int health_check_interval_ms;  // How often to check health
    int source_timeout_ms;         // How long before source is unhealthy
    int startup_grace_period_ms;   // Grace period after startup before health checks
    int64_t startup_time;          // Time when demuxer was initialized
    pthread_t health_thread;
    int health_running;
    int64_t last_health_check;
    
    // Reconnection control
    int reconnect_timeout_ms;      // Timeout for reconnection attempts (0 = infinite, keep trying forever)
    
    // Clean switching control
    int clean_switch_enabled;      // Enable decoder flush + SPS/PPS injection for smooth manual switches
    
#if HAVE_SRT
    // Integrated SRT relay for transparent SRT support
    SRTRelay srt_relay;
#endif
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
    ff_mutex_init(&buf->mutex, NULL);
    ff_cond_init(&buf->cond, NULL);
    buf->last_iframe_index = -1;
    buf->last_sps_pps_index = -1;
    buf->has_iframe = 0;
}

static void packet_buffer_destroy(PacketBuffer *buf)
{
    ff_mutex_lock(&buf->mutex);
    for (int i = 0; i < buf->count; i++) {
        int idx = (buf->read_index + i) % PACKET_BUFFER_SIZE;
        if (buf->packets[idx]) {
            av_packet_free(&buf->packets[idx]);
        }
    }
    ff_mutex_unlock(&buf->mutex);
    ff_mutex_destroy(&buf->mutex);
    ff_cond_destroy(&buf->cond);
}

static int packet_buffer_put(PacketBuffer *buf, AVPacket *pkt)
{
    ff_mutex_lock(&buf->mutex);
    
    if (buf->eof) {
        ff_mutex_unlock(&buf->mutex);
        return -1;
    }
    
    // Ring buffer: if full, drop oldest packet to make room
    if (buf->count >= PACKET_BUFFER_SIZE) {
        // If we're dropping the last I-frame, invalidate it
        if (buf->read_index == buf->last_iframe_index) {
            buf->has_iframe = 0;
            buf->last_iframe_index = -1;
        }
        
        // Free the oldest packet
        if (buf->packets[buf->read_index]) {
            av_packet_free(&buf->packets[buf->read_index]);
        }
        buf->read_index = (buf->read_index + 1) % PACKET_BUFFER_SIZE;
        buf->count--;
    }
    
    // Allocate and copy packet
    buf->packets[buf->write_index] = av_packet_clone(pkt);
    
    // Detect SPS/PPS/IDR for H.264 to track parameter sets
    int is_sps_pps = 0;
    int is_idr = 0;
    if (pkt->size > 4) {
        const uint8_t *data = pkt->data;
        int size = pkt->size;
        // Check for NAL unit type 7 (SPS), 8 (PPS), or 5 (IDR)
        for (int i = 0; i < size - 4; i++) {
            if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
                int nal_type = data[i+3] & 0x1F;
                if (nal_type == 7 || nal_type == 8) {
                    is_sps_pps = 1;
                    break;
                } else if (nal_type == 5) {
                    is_idr = 1;
                    break;
                }
            } else if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1 && i+4 < size) {
                int nal_type = data[i+4] & 0x1F;
                if (nal_type == 7 || nal_type == 8) {
                    is_sps_pps = 1;
                    break;
                } else if (nal_type == 5) {
                    is_idr = 1;
                    break;
                }
            }
        }
    }
    
    // Track SPS/PPS packets (they come before I-frames)
    if (is_sps_pps) {
        buf->last_sps_pps_index = buf->write_index;
        av_log(NULL, AV_LOG_DEBUG, "[PacketBuffer] Detected SPS/PPS at index %d\n", buf->write_index);
    }
    
    // Track I-frames and associate them with their SPS/PPS
    if (pkt->flags & AV_PKT_FLAG_KEY || is_idr) {
        buf->last_iframe_index = buf->write_index;
        buf->has_iframe = 1;
        av_log(NULL, AV_LOG_DEBUG, "[PacketBuffer] Detected I-frame at index %d (flags=0x%x, is_idr=%d), SPS/PPS at %d\n", 
               buf->write_index, pkt->flags, is_idr, buf->last_sps_pps_index);
        // If we don't have SPS/PPS tracked yet, assume it's right before this I-frame
        if (buf->last_sps_pps_index == -1 && buf->count > 0) {
            // Look back a few packets for SPS/PPS
            int lookback = (buf->write_index - 3 + PACKET_BUFFER_SIZE) % PACKET_BUFFER_SIZE;
            buf->last_sps_pps_index = lookback;
            av_log(NULL, AV_LOG_DEBUG, "[PacketBuffer] No SPS/PPS found, using lookback to index %d\n", lookback);
        }
    }
    
    buf->write_index = (buf->write_index + 1) % PACKET_BUFFER_SIZE;
    buf->count++;
    
    ff_cond_signal(&buf->cond);
    ff_mutex_unlock(&buf->mutex);
    
    return 0;
}

static int packet_buffer_get(PacketBuffer *buf, AVPacket *pkt)
{
    ff_mutex_lock(&buf->mutex);
    
    // Wait if buffer is empty
    while (buf->count == 0 && !buf->eof) {
        ff_cond_wait(&buf->cond, &buf->mutex);
    }
    
    if (buf->count == 0 && buf->eof) {
        ff_mutex_unlock(&buf->mutex);
        return AVERROR_EOF;
    }
    
    // Move packet from buffer
    av_packet_move_ref(pkt, buf->packets[buf->read_index]);
    av_packet_free(&buf->packets[buf->read_index]);
    buf->read_index = (buf->read_index + 1) % PACKET_BUFFER_SIZE;
    buf->count--;
    
    ff_cond_signal(&buf->cond);
    ff_mutex_unlock(&buf->mutex);
    
    return 0;
}

// Non-blocking version for checking if packets are available
static int packet_buffer_try_get(PacketBuffer *buf, AVPacket *pkt)
{
    ff_mutex_lock(&buf->mutex);
    
    // Don't wait, just check if buffer has packets
    if (buf->count == 0) {
        ff_mutex_unlock(&buf->mutex);
        return AVERROR(EAGAIN);  // No packets available
    }
    
    // Move packet from buffer
    av_packet_move_ref(pkt, buf->packets[buf->read_index]);
    av_packet_free(&buf->packets[buf->read_index]);
    buf->read_index = (buf->read_index + 1) % PACKET_BUFFER_SIZE;
    buf->count--;
    
    ff_cond_signal(&buf->cond);
    ff_mutex_unlock(&buf->mutex);
    
    return 0;
}

// Get packet from buffer, starting from the last I-frame if available
// This ensures we always start decoding from a clean point when switching sources
// Rewinds to SPS/PPS if available to ensure decoder has parameter sets
static int packet_buffer_get_from_iframe(PacketBuffer *buf, AVPacket *pkt)
{
    ff_mutex_lock(&buf->mutex);
    
    // If we have an I-frame in the buffer, rewind to SPS/PPS or I-frame
    if (buf->has_iframe && buf->last_iframe_index >= 0) {
        // Prefer to start from SPS/PPS if we have it, otherwise start from I-frame
        if (buf->last_sps_pps_index >= 0) {
            av_log(NULL, AV_LOG_DEBUG, "[PacketBuffer] Rewinding to SPS/PPS at index %d (I-frame at %d)\n", 
                   buf->last_sps_pps_index, buf->last_iframe_index);
            buf->read_index = buf->last_sps_pps_index;
        } else {
            av_log(NULL, AV_LOG_DEBUG, "[PacketBuffer] Rewinding to I-frame at index %d (no SPS/PPS tracked)\n", 
                   buf->last_iframe_index);
            buf->read_index = buf->last_iframe_index;
        }
        
        // Recalculate count from rewind point to write_index
        if (buf->write_index >= buf->read_index) {
            buf->count = buf->write_index - buf->read_index;
        } else {
            buf->count = PACKET_BUFFER_SIZE - buf->read_index + buf->write_index;
        }
        buf->has_iframe = 0;  // Mark as consumed
        buf->last_iframe_index = -1;
        buf->last_sps_pps_index = -1;
    }
    
    // Wait if buffer is empty
    while (buf->count == 0 && !buf->eof) {
        ff_cond_wait(&buf->cond, &buf->mutex);
    }
    
    if (buf->eof && buf->count == 0) {
        ff_mutex_unlock(&buf->mutex);
        return AVERROR_EOF;
    }
    
    // Get packet from buffer
    av_packet_move_ref(pkt, buf->packets[buf->read_index]);
    av_packet_free(&buf->packets[buf->read_index]);
    buf->read_index = (buf->read_index + 1) % PACKET_BUFFER_SIZE;
    buf->count--;
    
    ff_mutex_unlock(&buf->mutex);
    
    return 0;
}

// Reader thread - continuously reads from a source into its buffer
// Supports automatic reconnection for UDP sources
// For SRT: keeps connections alive, only reconnects on true connection loss
static void *source_reader_thread(void *arg)
{
    MSwitchSource *source = (MSwitchSource *)arg;
    MSwitchDirectContext *ctx = (MSwitchDirectContext *)source->parent_ctx;
    AVPacket *pkt = av_packet_alloc();
    int ret;
    int consecutive_errors = 0;
    
    // Detect if this is an SRT source
    int is_srt = (strncmp(source->url, "srt://", 6) == 0);
    
    av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Reader] Source %d: Reader thread started for %s (protocol: %s)\n", 
           source->source_index, source->url, is_srt ? "SRT" : "other");
    
    while (source->thread_running) {
        // Safety check: if fmt_ctx is NULL (reconnect failed), treat as error and retry
        if (!source->fmt_ctx) {
            consecutive_errors++;
            av_usleep(10000); // Wait 10ms
            
            // After 100 consecutive errors (~1 second), try to reconnect
            if (consecutive_errors >= 100) {
                // Will trigger reconnection below
                ret = AVERROR(EIO);
                goto handle_error;
            }
            continue;
        }
        
        ret = av_read_frame(source->fmt_ctx, pkt);
        
handle_error:
        if (ret < 0) {
            // Different error handling for SRT vs UDP
            // SRT: EAGAIN/ETIMEDOUT are normal (no data available), keep connection alive
            // UDP: Treat most errors as recoverable and attempt reconnect
            int is_temporary_error = (ret == AVERROR(EAGAIN) || ret == AVERROR(ETIMEDOUT));
            int is_connection_lost = (ret == AVERROR_EOF || 
                                      ret == AVERROR(EIO) ||
                                      ret == AVERROR(ECONNRESET) ||
                                      ret == AVERROR(EPIPE));
            
            // For SRT with temporary errors: just wait and retry, don't reconnect
            if (is_srt && is_temporary_error) {
                // This is normal for SRT - no data available right now
                // Just wait a bit and try again, keep connection alive
                av_usleep(10000); // Wait 10ms
                av_packet_unref(pkt);
                continue;
            }
            
            // For connection loss or UDP errors: attempt reconnection
            int should_reconnect = is_connection_lost || !is_srt;
            
            if (should_reconnect) {
                // No data available - do NOT update last_packet_time
                // This allows health monitoring to detect source loss
                consecutive_errors++;
                
                if (consecutive_errors == 1) {
                    av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Reader] Source %d: Read error: %s (%s)\n", 
                           source->source_index, av_err2str(ret), 
                           is_srt ? "SRT connection lost" : "will attempt reconnect");
                }
                
                // After 100 consecutive errors (~1 second), try to reconnect
                if (consecutive_errors >= 100) {
                    // Check if we should give up based on reconnect timeout
                    int64_t current_time = av_gettime() / 1000;
                    if (source->reconnect_start_time == 0) {
                        source->reconnect_start_time = current_time;
                        av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct Reader] Source %d: No data for 1s (consecutive_errors=%d), attempting reconnect%s...\n", 
                               source->source_index, consecutive_errors, ctx->reconnect_timeout_ms == 0 ? " (infinite)" : "");
                    }
                    
                    // Check timeout (0 = infinite, keep trying forever)
                    if (ctx->reconnect_timeout_ms > 0) {
                        int64_t time_reconnecting = current_time - source->reconnect_start_time;
                        if (time_reconnecting > ctx->reconnect_timeout_ms) {
                            av_log(NULL, AV_LOG_ERROR, "[MSwitch Direct Reader] Source %d: Reconnect timeout after %lldms, giving up\n", 
                                   source->source_index, time_reconnecting);
                            break;  // Exit thread
                        }
                    }
                    
                    av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Reader] Source %d: Closing and reopening connection (consecutive_errors=%d)...\n", 
                           source->source_index, consecutive_errors);
                    
                    // Close and reopen the source
                    if (source->fmt_ctx) {
                        avformat_close_input(&source->fmt_ctx);
                    }
                    
                    // Allocate new format context
                    source->fmt_ctx = avformat_alloc_context();
                    
                    AVDictionary *opts = NULL;
                    // Use longer timeout for SRT connections (5 seconds vs 100ms for UDP)
                    av_dict_set(&opts, "timeout", is_srt ? "5000000" : "100000", 0);
                    
                    av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Reader] Source %d: Attempting to open %s (%s)...\n", 
                           source->source_index, source->url, is_srt ? "SRT" : "UDP");
                    
                    ret = avformat_open_input(&source->fmt_ctx, source->url, NULL, &opts);
                    av_dict_free(&opts);
                    
                    if (ret < 0) {
                        av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Reader] Source %d: Reconnect attempt failed: %s (will retry)\n", 
                               source->source_index, av_err2str(ret));
                        // Set fmt_ctx to NULL since open failed - we'll allocate a new one on next attempt
                        source->fmt_ctx = NULL;
                        // DO NOT reset consecutive_errors - keep counting to trigger next reconnect attempt
                        av_usleep(100000); // Wait 100ms before next attempt
                        av_packet_unref(pkt);
                        continue;  // Skip to next iteration, don't try to read from NULL fmt_ctx
                    } else {
                        av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Reader] Source %d: ✅ Reconnected successfully! Finding stream info...\n", 
                               source->source_index);
                        
                        // Need to find stream info again after reconnect
                        ret = avformat_find_stream_info(source->fmt_ctx, NULL);
                        if (ret < 0) {
                            av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct Reader] Source %d: Failed to find stream info after reconnect: %s\n", 
                                   source->source_index, av_err2str(ret));
                        }
                        
                        source->fmt_ctx->flags |= AVFMT_FLAG_IGNDTS;
                        consecutive_errors = 0;
                        source->reconnect_start_time = 0;  // Reset reconnection timer
                        
                        // Clear EOF flag to allow reading again
                        ff_mutex_lock(&source->buffer.mutex);
                        source->buffer.eof = 0;
                        ff_mutex_unlock(&source->buffer.mutex);
                        
                        av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Reader] Source %d: Ready to read packets again\n", 
                               source->source_index);
                    }
                }
                
                av_usleep(10000); // 10ms
                av_packet_unref(pkt);
                continue;
            }
            // Fatal error
            av_log(NULL, AV_LOG_ERROR, "[MSwitch Direct Reader] Source %d: Fatal error: %s\n", 
                   source->source_index, av_err2str(ret));
            break;
        }
        
        consecutive_errors = 0;  // Reset on successful read
        source->reconnect_start_time = 0;  // Reset reconnection timer on successful read
        
        // Update health stats ONLY on successful read - track when UDP is actively receiving
        source->last_packet_time = av_gettime() / 1000; // Convert to milliseconds
        source->packets_read++;
        
        // Log first packet and every 100th packet after reconnection
        if (source->packets_read == 1) {
            av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Reader] Source %d: Received first packet (size=%d)\n", 
                   source->source_index, pkt->size);
        } else if (source->packets_read % 100 == 0) {
            av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Reader] Source %d: Received %lld packets (latest size=%d)\n", 
                   source->source_index, source->packets_read, pkt->size);
        }
        
        // Cache SPS/PPS packets for decoder recovery on switch
        if (pkt->size > 4) {
            const uint8_t *data = pkt->data;
            int size = pkt->size;
            int found_sps = 0, found_pps = 0;
            
            // Scan for SPS (NAL type 7) or PPS (NAL type 8)
            for (int i = 0; i < size - 4; i++) {
                if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
                    int nal_type = data[i+3] & 0x1F;
                    if (nal_type == 7) found_sps = 1;
                    else if (nal_type == 8) found_pps = 1;
                } else if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1 && i+4 < size) {
                    int nal_type = data[i+4] & 0x1F;
                    if (nal_type == 7) found_sps = 1;
                    else if (nal_type == 8) found_pps = 1;
                }
            }
            
            // Cache SPS packet
            if (found_sps) {
                if (source->cached_sps) {
                    av_packet_free(&source->cached_sps);
                }
                source->cached_sps = av_packet_clone(pkt);
                source->has_sps = 1;
                av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct] Source %d: Cached SPS packet\n", source->source_index);
            }
            
            // Cache PPS packet
            if (found_pps) {
                if (source->cached_pps) {
                    av_packet_free(&source->cached_pps);
                }
                source->cached_pps = av_packet_clone(pkt);
                source->has_pps = 1;
                av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct] Source %d: Cached PPS packet\n", source->source_index);
            }
        }
        
        // Put packet in buffer
        if (packet_buffer_put(&source->buffer, pkt) < 0) {
            break;
        }
        
        av_packet_unref(pkt);
    }
    
    av_packet_free(&pkt);
    ff_mutex_lock(&source->buffer.mutex);
    source->buffer.eof = 1;
    ff_cond_broadcast(&source->buffer.cond);
    ff_mutex_unlock(&source->buffer.mutex);
    
    return NULL;
}

// Health monitoring thread - checks source health and performs auto-failover
static void *health_monitor_thread(void *arg)
{
    MSwitchDirectContext *ctx = (MSwitchDirectContext *)arg;
    int64_t current_time;
    int i, best_source;
    
    av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Health] Starting health monitor (timeout: %dms, check interval: %dms, grace period: %dms)\n",
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
        ff_mutex_lock(&ctx->state_mutex);
        int active = ctx->active_source_index;
        ff_mutex_unlock(&ctx->state_mutex);
        
        // Check health of all sources
        for (i = 0; i < ctx->num_sources; i++) {
            MSwitchSource *src = &ctx->sources[i];
            int is_source_healthy;
            
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
                    av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Health] Source %d (ACTIVE) recovered\n", i);
                }
            } else {
                // Inactive source: check both buffer and recent packet activity
                ff_mutex_lock(&src->buffer.mutex);
                int buffer_count = src->buffer.count;
                ff_mutex_unlock(&src->buffer.mutex);
                
                // Consider healthy if either:
                // 1. Buffer has packets (ready for immediate failover), OR
                // 2. Received packets recently (actively reconnecting/filling buffer)
                int64_t time_since_packet = current_time - src->last_packet_time;
                is_source_healthy = (buffer_count > 0) || (time_since_packet <= ctx->source_timeout_ms);
                
                // Update health status and log changes
                if (!is_source_healthy && src->is_healthy) {
                    src->is_healthy = 0;
                    av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct Health] Source %d (inactive) unhealthy (buffer empty, no recent packets)\n", i);
                } else if (is_source_healthy && !src->is_healthy) {
                    src->is_healthy = 1;
                    av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Health] Source %d (inactive) recovered (buffer=%d, last_packet=%lldms ago)\n", 
                           i, buffer_count, time_since_packet);
                }
            }
        }
        
        // Check if active source is unhealthy (we already have 'active' from above)
        if (!ctx->sources[active].is_healthy) {
            // Determine failover target based on two-stage strategy:
            // Find best healthy source (simple failover - freeze-frame handles the rest)
            best_source = -1;
            for (i = 0; i < ctx->num_sources; i++) {
                if (i != active && ctx->sources[i].is_healthy) {
                    best_source = i;
                    av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Health] Found healthy source %d for failover\n", i);
                    break;
                }
            }
            
            if (best_source >= 0) {
                // Just log that a healthy source is available
                // The actual switch will happen in read_packet when it detects unhealthy source
                av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Health] Healthy source %d available for auto-failover\n", best_source);
            } else {
                av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct Health] No healthy sources available for failover\n");
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
                ff_mutex_lock(&ctx->state_mutex);
                
                // Check if target source is healthy
                int is_healthy = ctx->sources[new_source].is_healthy;
                int old_source = ctx->active_source_index;
                
                if (!is_healthy) {
                    ff_mutex_unlock(&ctx->state_mutex);
                    av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct HTTP] Cannot switch to source %d - source is UNHEALTHY\n",
                           new_source);
                    
                    snprintf(response, sizeof(response),
                             "HTTP/1.1 503 Service Unavailable\r\n"
                             "Content-Type: application/json\r\n"
                             "Content-Length: 45\r\n"
                             "\r\n"
                             "{\"error\":\"Source is unhealthy or offline\"}");
                    write(client_socket, response, strlen(response));
                    close(client_socket);
                    continue;
                }
                
                ctx->active_source_index = new_source;
                ctx->last_manual_switch_time = av_gettime() / 1000;  // Record manual switch time
                
                // DO NOT reset timestamps - let timestamp normalization handle continuity
                // This prevents jumps when the new source's buffer has old packets
                
                // If clean_switch is enabled, signal decoder flush for smooth transition
                if (ctx->clean_switch_enabled && old_source != new_source) {
                    ctx->need_decoder_flush = 1;
                    ctx->need_sps_pps_injection = 1;
                    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct HTTP] Manual switch %d → %d (clean_switch enabled, will flush decoder)\n",
                           old_source, new_source);
                } else {
                    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct HTTP] Manual switch %d → %d (immediate)\n",
                           old_source, new_source);
                }
                ff_mutex_unlock(&ctx->state_mutex);
                
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
    
    av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Initializing with sources: %s\n", ctx->sources_str);
    
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
        source->parent_ctx = ctx;  // Set parent context for reconnection timeout access
        source->reconnect_start_time = 0;  // Initialize reconnection timer
        
        av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Opening source %d: %s\n", ctx->num_sources, source_url);
        
        // Detect protocol and set appropriate timeout
        int is_srt_source = (strncmp(source_url, "srt://", 6) == 0);
        
        // Set timeout (in microseconds): SRT needs longer for connection establishment
        AVDictionary *opts = NULL;
        av_dict_set(&opts, "timeout", is_srt_source ? "5000000" : "100000", 0);  // 5s for SRT, 100ms for UDP
        
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
        
        // For SRT: use minimal probing to avoid keeping connection open too long
        // This prevents the listener from timing out during initialization
        if (is_srt_source) {
            source->fmt_ctx->probesize = 32768;  // 32KB instead of default 5MB
            source->fmt_ctx->max_analyze_duration = 1000000;  // 1 second instead of 5 seconds
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
        source->last_consumption_time = 0; // Will be set when first packet consumed
        source->packets_read = 0;
        source->is_healthy = 1; // Assume healthy initially
        
        // Initialize freeze-frame support
        source->last_good_packet = NULL;
        source->has_good_packet = 0;
        
        // Initialize cached parameter sets from stream extradata
        source->cached_sps = NULL;
        source->cached_pps = NULL;
        source->has_sps = 0;
        source->has_pps = 0;
        
        // Extract SPS/PPS from stream extradata if available
        if (source->fmt_ctx->nb_streams > 0) {
            AVCodecParameters *codecpar = source->fmt_ctx->streams[0]->codecpar;
            if (codecpar->extradata_size > 0 && codecpar->extradata) {
                av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Source %d has extradata (%d bytes), extracting SPS/PPS\n",
                       ctx->num_sources, codecpar->extradata_size);
                
                // Store entire extradata as a single "SPS+PPS" packet for injection
                source->cached_sps = av_packet_alloc();
                if (source->cached_sps) {
                    av_new_packet(source->cached_sps, codecpar->extradata_size);
                    memcpy(source->cached_sps->data, codecpar->extradata, codecpar->extradata_size);
                    source->has_sps = 1;
                    source->has_pps = 1;  // Mark both as available since extradata contains both
                    av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Source %d: Cached extradata as SPS/PPS\n", ctx->num_sources);
                }
            } else {
                av_log(s, AV_LOG_WARNING, "[MSwitch Direct] Source %d has no extradata - SPS/PPS injection may not work!\n",
                       ctx->num_sources);
            }
        }
        
        // Don't start reader thread yet - wait until all sources are opened
        // This prevents SRT connection issues during initialization
        source->thread_running = 0;
        
        ctx->num_sources++;
        source_url = av_strtok(NULL, ",", &saveptr);
    }
    
    av_freep(&sources_copy);
    
    if (ctx->num_sources == 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Direct] No sources provided\n");
        return AVERROR(EINVAL);
    }
    
    // Now start all reader threads after all sources are opened
    // This prevents connection issues during sequential source opening
    av_log(s, AV_LOG_INFO, "[MSwitch Direct] All sources opened, starting reader threads...\n");
    for (i = 0; i < ctx->num_sources; i++) {
        ctx->sources[i].thread_running = 1;
        pthread_create(&ctx->sources[i].reader_thread, NULL, source_reader_thread, &ctx->sources[i]);
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
    
    ff_mutex_init(&ctx->state_mutex, NULL);
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
    ctx->freeze_frame_active = 0;
    ctx->freeze_frame_duration = 3000;  // Default: 30fps = 3000 ticks at 90kHz timebase (will be calculated from actual stream)
    ctx->need_decoder_flush = 0;
    ctx->need_sps_pps_injection = 0;
    ctx->pending_first_packet = NULL;
    
    // Start health monitoring thread if auto-failover enabled
    if (ctx->auto_failover_enabled) {
        ctx->health_running = 1;
        ctx->startup_time = av_gettime() / 1000;  // Record startup time
        ctx->last_health_check = ctx->startup_time;
        pthread_create(&ctx->health_thread, NULL, health_monitor_thread, ctx);
        av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Auto-failover enabled (timeout: %dms, check interval: %dms, grace period: %dms)\n",
               ctx->source_timeout_ms, ctx->health_check_interval_ms, ctx->startup_grace_period_ms);
    } else {
        ctx->health_running = 0;
        av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Auto-failover disabled\n");
    }
    
    // Set global context for CLI control
    global_mswitchdirect_ctx = ctx;
    
    av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Initialized with %d sources, control port %d\n", 
           ctx->num_sources, ctx->control_port);
    av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] CLI controls: Press 0-%d to switch sources, 'm' for status\n",
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
    
    ff_mutex_lock(&ctx->state_mutex);
    active_source = ctx->active_source_index;
    pending_switch = ctx->pending_switch_to;
    
    // Check if we need to send a flush packet
    if (ctx->need_decoder_flush) {
        ctx->need_decoder_flush = 0;
        ctx->need_sps_pps_injection = 1;  // After flush, we need to inject SPS/PPS
        ff_mutex_unlock(&ctx->state_mutex);
        
        // Send an empty packet to signal flush (size=0, data=NULL)
        av_init_packet(pkt);
        pkt->data = NULL;
        pkt->size = 0;
        pkt->stream_index = 0;
        
        av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] 🔄 Sending flush packet to decoder\n");
        return 0;
    }
    
    // Check if we need to inject SPS/PPS (after flush, before I-frame)
    if (ctx->need_sps_pps_injection) {
        ctx->need_sps_pps_injection = 0;
        
        // Check if we have extradata for this source
        if (ctx->sources[active_source].has_sps && ctx->sources[active_source].cached_sps) {
            ff_mutex_unlock(&ctx->state_mutex);
            
            AVPacket *extradata_pkt = ctx->sources[active_source].cached_sps;
            
            // Create a packet with the extradata
            av_new_packet(pkt, extradata_pkt->size);
            memcpy(pkt->data, extradata_pkt->data, extradata_pkt->size);
            pkt->stream_index = 0;
            
            // Set timestamps to 0 for SPS/PPS packet (they don't have meaningful timestamps)
            pkt->pts = 0;
            pkt->dts = 0;
            pkt->flags = 0;  // Not a keyframe, just metadata
            
            av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] 💉 Injecting SPS/PPS extradata for source %d (%d bytes, pts=0, dts=0)\n",
                   active_source, extradata_pkt->size);
            return 0;
        } else {
            av_log(s, AV_LOG_WARNING, "[MSwitch Direct] ⚠️  No SPS/PPS extradata available for source %d, skipping injection\n",
                   active_source);
            ff_mutex_unlock(&ctx->state_mutex);
        }
    }
    
    // Output pending first packet if available (after flush and SPS/PPS injection)
    if (ctx->pending_first_packet) {
        AVPacket *cached = ctx->pending_first_packet;
        ctx->pending_first_packet = NULL;
        ff_mutex_unlock(&ctx->state_mutex);
        
        av_packet_ref(pkt, cached);
        av_packet_free(&cached);
        
        av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] 📦 Outputting first I-frame from source %d after flush+SPS/PPS (flags=0x%x, size=%d)\n",
               active_source, pkt->flags, pkt->size);
        
        // Continue to timestamp normalization below
        goto normalize_timestamps;
    }
    
    ff_mutex_unlock(&ctx->state_mutex);
    
    // Skip the old pending switch logic - we now do immediate switches below
    // If there's a pending switch, try to read from the new source
    if (0 && pending_switch >= 0) {  // DISABLED - using immediate switch instead
        av_log(s, AV_LOG_INFO, "[MSwitch Direct] 🔄 PENDING SWITCH: Attempting to read from source %d (active=%d)\n", 
               pending_switch, active_source);
        
        // Try to get a packet from the pending source (non-blocking)
        ret = packet_buffer_try_get(&ctx->sources[pending_switch].buffer, pkt);
        if (ret < 0) {
            // Pending source has no packets, try current source (also non-blocking to avoid deadlock)
            av_log(s, AV_LOG_INFO, "[MSwitch Direct] ⚠️  Pending source %d has no packets (%s), trying source %d\n",
                   pending_switch, av_err2str(ret), active_source);
            ret = packet_buffer_try_get(&ctx->sources[active_source].buffer, pkt);
            if (ret < 0) {
                // Active source is empty and we have a pending switch - force switch now!
                av_log(s, AV_LOG_WARNING, "[MSwitch Direct] Active source %d empty, forcing switch to %d\n", 
                       active_source, pending_switch);
                
                // Force switch by clearing wait_for_iframe
                ff_mutex_lock(&ctx->state_mutex);
                ctx->wait_for_iframe = 0;
                ff_mutex_unlock(&ctx->state_mutex);
                
                // Try to get packet from pending source, starting from last I-frame if available
                ret = packet_buffer_get_from_iframe(&ctx->sources[pending_switch].buffer, pkt);
                if (ret < 0) {
                    return ret;
                }
                
                // Execute the switch - we now have a packet starting from an I-frame
                ff_mutex_lock(&ctx->state_mutex);
                int old_source = ctx->active_source_index;
                ctx->active_source_index = pending_switch;
                ctx->pending_switch_to = -1;
                ctx->wait_for_iframe = 0;
                ctx->first_packet = 1;
                ctx->last_output_pts = AV_NOPTS_VALUE;
                ctx->last_output_dts = AV_NOPTS_VALUE;
                ctx->ts_offset[pending_switch] = 0;
                ctx->freeze_frame_active = 0;  // Exit freeze-frame mode on successful switch
                
                // Signal decoder flush, then cache I-frame to output after flush
                ctx->need_decoder_flush = 1;
                
                if (!ctx->pending_first_packet) {
                    ctx->pending_first_packet = av_packet_alloc();
                }
                av_packet_unref(ctx->pending_first_packet);
                av_packet_ref(ctx->pending_first_packet, pkt);
                
                ff_mutex_unlock(&ctx->state_mutex);
                
                av_log(s, AV_LOG_WARNING, "[MSwitch Direct] ✅ SWITCHED: Source %d → %d (forced from buffer I-frame) (flags=0x%x, will flush decoder then output I-frame)\n",
                       old_source, pending_switch, pkt->flags);
                
                // Return EAGAIN so next read will flush decoder
                av_packet_unref(pkt);
                return AVERROR(EAGAIN);
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
            
            // Only switch on I-frames for clean decoder recovery
            if (is_keyframe) {
                // Execute the switch
                ff_mutex_lock(&ctx->state_mutex);
                int old_source = ctx->active_source_index;
                ctx->active_source_index = pending_switch;
                ctx->pending_switch_to = -1;
                ctx->wait_for_iframe = 0;
                
                // Reset timestamp tracking for new source
                ctx->first_packet = 1;
                ctx->last_output_pts = AV_NOPTS_VALUE;
                ctx->last_output_dts = AV_NOPTS_VALUE;
                ctx->ts_offset[pending_switch] = 0;
                ctx->freeze_frame_active = 0;  // Exit freeze-frame mode on successful switch
                
                // Signal decoder flush, then cache I-frame to output after flush
                ctx->need_decoder_flush = 1;
                
                if (!ctx->pending_first_packet) {
                    ctx->pending_first_packet = av_packet_alloc();
                }
                av_packet_unref(ctx->pending_first_packet);
                av_packet_ref(ctx->pending_first_packet, pkt);
                
                ff_mutex_unlock(&ctx->state_mutex);
                
                av_log(s, AV_LOG_WARNING, "[MSwitch Direct] ✅ SWITCHED: Source %d → %d (I-frame) (flags=0x%x, will flush decoder then output I-frame)\n",
                       old_source, pending_switch, pkt->flags);
                
                // Return EAGAIN so next read will flush decoder
                av_packet_unref(pkt);
                return AVERROR(EAGAIN);
            } else {
                // Not an I-frame yet, continue freeze-frame while waiting
                av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Waiting for I-frame from source %d (flags=0x%x), continuing freeze-frame\n",
                       pending_switch, pkt->flags);
                av_packet_unref(pkt);
                
                // Continue freeze-frame from old source
                MSwitchSource *old_source = &ctx->sources[active_source];
                if (old_source->has_good_packet && old_source->last_good_packet) {
                    av_packet_ref(pkt, old_source->last_good_packet);
                    
                    // Increment timestamps for smooth playback
                    if (pkt->pts != AV_NOPTS_VALUE) {
                        pkt->pts = ctx->last_output_pts + 3000;  // Assume 30fps (90000/30 = 3000)
                    }
                    if (pkt->dts != AV_NOPTS_VALUE) {
                        pkt->dts = ctx->last_output_dts + 3000;
                    }
                    
                    ctx->last_output_pts = pkt->pts;
                    ctx->last_output_dts = pkt->dts;
                    
                    av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] ❄️  Freeze-frame: repeating last packet while waiting for I-frame (pts=%lld, dts=%lld)\n",
                           pkt->pts, pkt->dts);
                    
                    return 0;
                } else {
                    // No freeze-frame available, wait
                    av_usleep(10000);  // Sleep 10ms
                    return AVERROR(EAGAIN);
                }
            }
        }
    } else {
        // No pending switch, normal operation
        // BUT: Check if active source is unhealthy BEFORE reading from buffer
        // This ensures immediate failover without draining stale buffer
        MSwitchSource *active = &ctx->sources[active_source];
        
        ff_mutex_lock(&ctx->state_mutex);
        int is_unhealthy = !active->is_healthy;
        ff_mutex_unlock(&ctx->state_mutex);
        
        if (is_unhealthy && ctx->auto_failover_enabled) {
            // Active source is unhealthy - find a healthy source and switch immediately
            // Use the same simple switch mechanism as manual CLI switches (which work perfectly)
            av_log(s, AV_LOG_WARNING, "[MSwitch Direct] 🚨 Active source %d is UNHEALTHY - triggering immediate failover\n", active_source);
            
            // Find best healthy source
            int best_source = -1;
            ff_mutex_lock(&ctx->state_mutex);
            for (int i = 0; i < ctx->num_sources; i++) {
                if (i != active_source && ctx->sources[i].is_healthy) {
                    best_source = i;
                    break;
                }
            }
            
            if (best_source >= 0) {
                // Perform immediate switch for auto-failover (no flush, no timestamp reset)
                // This preserves timestamp continuity and allows freeze-frame to work
                int old_source = ctx->active_source_index;
                ctx->active_source_index = best_source;
                ctx->last_manual_switch_time = av_gettime() / 1000;  // Record switch time for grace period
                
                // DO NOT reset timestamps for auto-failover - keep continuity
                // The timestamp normalization code will adjust the offset automatically
                
                ff_mutex_unlock(&ctx->state_mutex);
                
                av_log(s, AV_LOG_WARNING, "[MSwitch Direct] ⚡ AUTO-FAILOVER: Switched from source %d to %d (immediate, preserving timestamps)\n",
                       old_source, best_source);
                
                // Return EAGAIN to retry read_packet with new active source
                av_usleep(10000);  // Brief sleep to let new source buffer fill
                return AVERROR(EAGAIN);
            } else {
                ff_mutex_unlock(&ctx->state_mutex);
                av_log(s, AV_LOG_ERROR, "[MSwitch Direct] No healthy sources available!\n");
                av_usleep(100000);
                return AVERROR(EAGAIN);
            }
        }
        
        // Source is healthy, read from buffer normally
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
                
                // Check if we have a last good packet for freeze-frame
                MSwitchSource *source = &ctx->sources[active_source];
                if (source->has_good_packet && source->last_good_packet) {
                    // Enter freeze-frame mode
                    if (!ctx->freeze_frame_active) {
                        av_log(s, AV_LOG_WARNING, "[MSwitch Direct] ❄️  Source %d failed, entering FREEZE-FRAME mode\n", active_source);
                        ctx->freeze_frame_active = 1;
                        
                        // Health monitor will find next healthy source in background and set pending_switch_to
                    }
                    
                    // Output the last good packet with incremented timestamps
                    av_packet_ref(pkt, source->last_good_packet);
                    
                    // Increment timestamps to maintain continuity
                    if (ctx->last_output_pts != AV_NOPTS_VALUE) {
                        pkt->pts = ctx->last_output_pts + ctx->freeze_frame_duration;
                    }
                    if (ctx->last_output_dts != AV_NOPTS_VALUE) {
                        pkt->dts = ctx->last_output_dts + ctx->freeze_frame_duration;
                    }
                    
                    av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] ❄️  Freeze-frame: repeating last packet (pts=%lld, dts=%lld)\n",
                           pkt->pts, pkt->dts);
                    
                    // Successfully created freeze-frame packet - skip to timestamp normalization
                    goto normalize_timestamps;
                } else {
                    // No last good packet - fall back to finding healthy source immediately
                    av_log(s, AV_LOG_WARNING, "[MSwitch Direct] Active source %d EOF (no freeze-frame available), triggering immediate failover\n", active_source);
                    
                    // Find best healthy source
                    int best_source = -1;
                    for (int i = 0; i < ctx->num_sources; i++) {
                        if (i != active_source && ctx->sources[i].is_healthy) {
                            best_source = i;
                            break;
                        }
                    }
                    
                    if (best_source >= 0) {
                        // Set pending switch
                        ff_mutex_lock(&ctx->state_mutex);
                        if (ctx->pending_switch_to < 0) {  // No pending switch already
                            ctx->pending_switch_to = best_source;
                            ctx->wait_for_iframe = 1;
                            ctx->pending_switch_time = av_gettime() / 1000;
                            ff_mutex_unlock(&ctx->state_mutex);
                            av_log(s, AV_LOG_WARNING, "[MSwitch Direct] 🔄 IMMEDIATE FAILOVER: Source %d → %d\n",
                                   active_source, best_source);
                            // Retry read_packet, which will now hit the pending_switch path
                            return AVERROR(EAGAIN);
                        }
                        ff_mutex_unlock(&ctx->state_mutex);
                    }
                    
                    // No healthy source found, sleep and retry
                    av_log(s, AV_LOG_WARNING, "[MSwitch Direct] No healthy source available, waiting...\n");
                    av_usleep(100000);  // Sleep 100ms
                    return AVERROR(EAGAIN);
                }
            }
            return ret;
        } else {
            // Successfully read packet - store as last good packet for freeze-frame
            MSwitchSource *source = &ctx->sources[active_source];
            if (!source->last_good_packet) {
                source->last_good_packet = av_packet_alloc();
            }
            if (source->last_good_packet) {
                av_packet_unref(source->last_good_packet);
                av_packet_ref(source->last_good_packet, pkt);
                source->has_good_packet = 1;
            }
            
            // If we were in freeze-frame mode and now have a real packet, exit freeze-frame
            if (ctx->freeze_frame_active) {
                av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] ✅ Source %d recovered, exiting freeze-frame mode\n", active_source);
                ctx->freeze_frame_active = 0;
            }
        }
    }
    
    // Don't update last_packet_time here - it's updated by reader thread
    // This way we detect actual UDP source failures, not just consumption slowness
    
normalize_timestamps:
    // Log packet output for debugging
    {
        const char *source_type = ctx->freeze_frame_active ? "FREEZE-FRAME" : 
                                  (pending_switch >= 0 ? "PENDING" : "NORMAL");
        const char *frame_type = (pkt->flags & AV_PKT_FLAG_KEY) ? "I" : "P";
        
        av_log(s, AV_LOG_DEBUG, "[MSwitch Direct OUTPUT] Source %d → Encoder | Type: %s | Frame: %s | Size: %d bytes | PTS: %lld\n",
               active_source, source_type, frame_type, pkt->size, pkt->pts);
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
    
    ff_mutex_lock(&global_mswitchdirect_ctx->state_mutex);
    int old_index = global_mswitchdirect_ctx->active_source_index;
    global_mswitchdirect_ctx->active_source_index = source_index;
    global_mswitchdirect_ctx->last_manual_switch_time = av_gettime() / 1000;  // Record manual switch time
    ff_mutex_unlock(&global_mswitchdirect_ctx->state_mutex);
    
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
    
    ff_mutex_lock(&ctx->state_mutex);
    int active = ctx->active_source_index;
    int total = ctx->num_sources;
    ff_mutex_unlock(&ctx->state_mutex);
    
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] ════════════════════════════════\n");
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] Active source: %d / %d\n", active, total - 1);
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] Auto-failover: %s\n",
           ctx->auto_failover_enabled ? "ENABLED" : "DISABLED");
    av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] ────────────────────────────────\n");
    
    // Show detailed status for each source
    int64_t current_time = av_gettime() / 1000;
    for (int i = 0; i < total; i++) {
        MSwitchSource *src = &ctx->sources[i];
        ff_mutex_lock(&src->buffer.mutex);
        int count = src->buffer.count;
        ff_mutex_unlock(&src->buffer.mutex);
        
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
    
    av_log(s, AV_LOG_DEBUG, "[MSwitch Direct] Closing\n");
    
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
        ff_mutex_lock(&source->buffer.mutex);
        source->buffer.eof = 1;
        ff_cond_broadcast(&source->buffer.cond);
        ff_mutex_unlock(&source->buffer.mutex);
        
        if (source->reader_thread) {
            pthread_join(source->reader_thread, NULL);
        }
        
        packet_buffer_destroy(&source->buffer);
        
        if (source->fmt_ctx) {
            avformat_close_input(&source->fmt_ctx);
        }
        
        // Free freeze-frame packet
        if (source->last_good_packet) {
            av_packet_free(&source->last_good_packet);
        }
        
        // Free cached parameter sets
        if (source->cached_sps) {
            av_packet_free(&source->cached_sps);
        }
        if (source->cached_pps) {
            av_packet_free(&source->cached_pps);
        }
        
        av_freep(&source->url);
    }
    
    ff_mutex_destroy(&ctx->state_mutex);
    
    return 0;
}

#define OFFSET(x) offsetof(MSwitchDirectContext, x)
#define DEC AV_OPT_FLAG_DECODING_PARAM

static const AVOption mswitchdirect_options[] = {
    { "msw_sources", "Comma-separated list of source URLs", OFFSET(sources_str), AV_OPT_TYPE_STRING, {.str = NULL}, 0, 0, DEC },
    { "msw_port", "Control port for HTTP switching", OFFSET(control_port), AV_OPT_TYPE_INT, {.i64 = MSW_CONTROL_PORT_DEFAULT}, 1024, 65535, DEC },
    { "msw_auto_failover", "Enable automatic failover on source failure", OFFSET(auto_failover_enabled), AV_OPT_TYPE_BOOL, {.i64 = 1}, 0, 1, DEC },
    { "msw_health_interval", "Health check interval in milliseconds", OFFSET(health_check_interval_ms), AV_OPT_TYPE_INT, {.i64 = 50}, 10, 10000, DEC },
    { "msw_source_timeout", "Source timeout in milliseconds before marked unhealthy", OFFSET(source_timeout_ms), AV_OPT_TYPE_INT, {.i64 = 300}, 10, 60000, DEC },
    { "msw_grace_period", "Startup grace period in milliseconds before health checks begin", OFFSET(startup_grace_period_ms), AV_OPT_TYPE_INT, {.i64 = 0}, 0, 60000, DEC },
    { "msw_reconnect_timeout", "Reconnection timeout in milliseconds (0 = infinite, keep trying forever)", OFFSET(reconnect_timeout_ms), AV_OPT_TYPE_INT, {.i64 = 0}, 0, 300000, DEC },
    { "msw_clean_switch", "Enable clean switching with decoder flush and SPS/PPS injection (slower but smoother)", OFFSET(clean_switch_enabled), AV_OPT_TYPE_BOOL, {.i64 = 0}, 0, 1, DEC },
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

