/*
 * MSwitch (Multi-Source Switch) demuxer
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
 * MSwitch demuxer
 * 
 * Usage: ffmpeg -i "mswitch://?sources=s0,s1,s2&control=8099" ...
 * 
 * This demuxer spawns subprocess FFmpeg instances for each source,
 * runs a UDP proxy to forward packets from the active source,
 * and provides an HTTP control interface for switching sources.
 */

#include <pthread.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include "libavutil/avstring.h"
#include "libavutil/bprint.h"
#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "avformat.h"
#include "demux.h"
#include "url.h"

#define MAX_SOURCES 10
#define MSW_BASE_UDP_PORT 13000
#define MSW_PROXY_OUTPUT_PORT 13100
#define MSW_UDP_PACKET_SIZE 65536
#define MSW_CONTROL_PORT_DEFAULT 8099
#define MSW_SUBPROCESS_STARTUP_DELAY_MS 2000

typedef struct MSwitchSource {
    char *url;                   // Source URL (e.g., "udp://...", "color=red", etc.)
    char *id;                    // Source ID (e.g., "s0", "s1", "s2")
    pid_t subprocess_pid;        // PID of subprocess FFmpeg
    int subprocess_running;      // Is subprocess running?
    int source_port;             // UDP port for this source's output
} MSwitchSource;

// Forward declare for thread arg
typedef struct MSwitchDemuxerContext MSwitchDemuxerContext;

typedef struct MSwitchThreadArg {
    AVFormatContext *s;
    MSwitchDemuxerContext *ctx;
} MSwitchThreadArg;

struct MSwitchDemuxerContext {
    const AVClass *class;
    
    // Configuration
    int num_sources;
    MSwitchSource sources[MAX_SOURCES];
    int active_source_index;
    int pending_source_index;    // For seamless mode: switch on next keyframe
    int last_active_source_index; // Track when switch actually happened
    int control_port;
    char *mode;                  // "seamless", "graceful", "cutover"
    
    // Mode flags
    int seamless_mode;           // Wait for keyframe
    int graceful_mode;           // Use raw frames
    int cutover_mode;            // Immediate switch
    
    // Subprocess management
    pthread_t monitor_thread;
    int monitor_running;
    MSwitchThreadArg monitor_arg;
    
    // UDP proxy
    int source_sockets[MAX_SOURCES];  // Sockets to receive from subprocesses
    int output_socket;                // Socket to send to internal consumer
    pthread_t proxy_thread;
    int proxy_running;
    MSwitchThreadArg proxy_arg;
    
    // Control server
    pthread_t control_thread;
    int control_socket;
    int control_running;
    MSwitchThreadArg control_arg;
    
    // Thread safety
    pthread_mutex_t state_mutex;
    
    // Internal input context (reads from proxy output)
    AVFormatContext *input_ctx;
    int input_opened;
};

// Forward declarations
static int mswitch_start_subprocesses(AVFormatContext *s, MSwitchDemuxerContext *ctx);
static int mswitch_stop_subprocesses(AVFormatContext *s, MSwitchDemuxerContext *ctx);
static void *mswitch_monitor_thread_func(void *arg);
static void *mswitch_proxy_thread_func(void *arg);
static void *mswitch_control_thread_func(void *arg);

// ============================================================================
// URL Parsing
// ============================================================================

static int parse_mswitch_url(AVFormatContext *s, const char *url)
{
    MSwitchDemuxerContext *ctx = s->priv_data;
    const char *query_start;
    char *query_copy = NULL;
    char *token, *saveptr;
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Parsing URL: %s\n", url);
    
    // Default values
    ctx->num_sources = 0;
    ctx->active_source_index = 0;
    ctx->last_active_source_index = 0;
    ctx->control_port = MSW_CONTROL_PORT_DEFAULT;
    ctx->mode = av_strdup("seamless");
    
    // Skip "mswitch://" prefix if present
    if (av_strstart(url, "mswitch://", &url)) {
        // Prefix was present, now url points after it
    }
    
    // Find query string (everything after '?')
    query_start = strchr(url, '?');
    if (query_start) {
        query_copy = av_strdup(query_start + 1);
    } else {
        // No '?' found, treat entire URL as query string
        query_copy = av_strdup(url);
    }
    if (!query_copy)
        return AVERROR(ENOMEM);
    
    // Parse query parameters
    token = av_strtok(query_copy, "&", &saveptr);
    while (token) {
        char *key = token;
        char *value = strchr(token, '=');
        
        if (value) {
            *value = '\0';
            value++;
            
            if (strcmp(key, "sources") == 0) {
                // Parse comma-separated sources
                char *source_token, *source_saveptr;
                source_token = av_strtok(value, ",", &source_saveptr);
                
                while (source_token && ctx->num_sources < MAX_SOURCES) {
                    MSwitchSource *src = &ctx->sources[ctx->num_sources];
                    
                    // Generate source ID
                    src->id = av_asprintf("s%d", ctx->num_sources);
                    src->url = av_strdup(source_token);
                    src->source_port = MSW_BASE_UDP_PORT + ctx->num_sources;
                    src->subprocess_pid = -1;
                    src->subprocess_running = 0;
                    
                    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Source %d: id=%s, url=%s, port=%d\n",
                           ctx->num_sources, src->id, src->url, src->source_port);
                    
                    ctx->num_sources++;
                    source_token = av_strtok(NULL, ",", &source_saveptr);
                }
            } else if (strcmp(key, "control") == 0) {
                ctx->control_port = atoi(value);
            } else if (strcmp(key, "mode") == 0) {
                av_freep(&ctx->mode);
                ctx->mode = av_strdup(value);
            }
        }
        
        token = av_strtok(NULL, "&", &saveptr);
    }
    
    av_freep(&query_copy);
    
    if (ctx->num_sources == 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] No sources specified\n");
        return AVERROR(EINVAL);
    }
    
    // Set mode flags
    ctx->pending_source_index = -1;  // No pending switch
    if (strcmp(ctx->mode, "seamless") == 0) {
        ctx->seamless_mode = 1;
        ctx->graceful_mode = 0;
        ctx->cutover_mode = 0;
    } else if (strcmp(ctx->mode, "graceful") == 0) {
        ctx->seamless_mode = 0;
        ctx->graceful_mode = 1;
        ctx->cutover_mode = 0;
    } else if (strcmp(ctx->mode, "cutover") == 0) {
        ctx->seamless_mode = 0;
        ctx->graceful_mode = 0;
        ctx->cutover_mode = 1;
    } else {
        // Default to seamless
        av_log(s, AV_LOG_WARNING, "[MSwitch Demuxer] Unknown mode '%s', using seamless\n", ctx->mode);
        ctx->seamless_mode = 1;
        ctx->graceful_mode = 0;
        ctx->cutover_mode = 0;
    }
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Parsed %d sources, control port=%d, mode=%s\n",
           ctx->num_sources, ctx->control_port, ctx->mode);
    
    return 0;
}

// ============================================================================
// Subprocess Management
// ============================================================================

static int mswitch_create_udp_socket(AVFormatContext *s, int port, int *sock_fd)
{
    struct sockaddr_in addr;
    int fd, ret;
    
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] Failed to create socket: %s\n", strerror(errno));
        return AVERROR(errno);
    }
    
    // Set SO_REUSEADDR
    int reuse = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) < 0) {
        av_log(s, AV_LOG_WARNING, "[MSwitch Demuxer] Failed to set SO_REUSEADDR: %s\n", strerror(errno));
    }
    
    // Set non-blocking
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
    
    // Bind
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr.sin_port = htons(port);
    
    ret = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (ret < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] Failed to bind to port %d: %s\n", port, strerror(errno));
        close(fd);
        return AVERROR(errno);
    }
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Created UDP socket on port %d\n", port);
    *sock_fd = fd;
    return 0;
}

static int mswitch_start_subprocess(AVFormatContext *s, int source_index)
{
    MSwitchDemuxerContext *ctx = s->priv_data;
    MSwitchSource *src = &ctx->sources[source_index];
    pid_t pid;
    char output_url[256];
    const char *ffmpeg_path = "ffmpeg";  // Assume ffmpeg is in PATH
    
    // Build output URL
    snprintf(output_url, sizeof(output_url), "udp://127.0.0.1:%d", src->source_port);
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Starting subprocess %d: %s -> %s\n",
           source_index, src->url, output_url);
    
    pid = fork();
    if (pid < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] fork() failed: %s\n", strerror(errno));
        return AVERROR(errno);
    }
    
    if (pid == 0) {
        // Child process
        // Redirect stderr to /dev/null to avoid clutter
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }
        
        // Determine input type
        char input_arg[512];
        if (strstr(src->url, "color=") == src->url || 
            strstr(src->url, "testsrc") == src->url ||
            strstr(src->url, "lavfi")) {
            // lavfi source
            snprintf(input_arg, sizeof(input_arg), "lavfi -i %s", src->url);
        } else {
            // Regular source
            snprintf(input_arg, sizeof(input_arg), "-i %s", src->url);
        }
        
        // Execute ffmpeg
        // Mode-specific encoding
        if (ctx->seamless_mode) {
            // Seamless: Encode with frequent keyframes for fast switching
            execlp(ffmpeg_path, ffmpeg_path,
                   "-f", "lavfi", "-i", src->url,
                   "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
                   "-g", "10", "-keyint_min", "10", "-sc_threshold", "0",  // Keyframe every 10 frames
                   "-pix_fmt", "yuv420p",
                   "-f", "mpegts", output_url,
                   NULL);
        } else if (ctx->graceful_mode) {
            // Graceful: Encode with normal settings, allow decoder to resync
            execlp(ffmpeg_path, ffmpeg_path,
                   "-f", "lavfi", "-i", src->url,
                   "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
                   "-g", "25", "-pix_fmt", "yuv420p",
                   "-f", "mpegts", output_url,
                   NULL);
        } else {
            // Cutover: Standard encoding
            execlp(ffmpeg_path, ffmpeg_path,
                   "-f", "lavfi", "-i", src->url,
                   "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
                   "-g", "50", "-pix_fmt", "yuv420p",
                   "-f", "mpegts", output_url,
                   NULL);
        }
        
        // If execlp returns, it failed
        _exit(1);
    }
    
    // Parent process
    src->subprocess_pid = pid;
    src->subprocess_running = 1;
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Started subprocess %d (PID: %d)\n",
           source_index, pid);
    
    return 0;
}

static int mswitch_start_subprocesses(AVFormatContext *s, MSwitchDemuxerContext *ctx)
{
    int i, ret;
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Starting %d subprocesses...\n", ctx->num_sources);
    
    for (i = 0; i < ctx->num_sources; i++) {
        ret = mswitch_start_subprocess(s, i);
        if (ret < 0) {
            av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] Failed to start subprocess %d\n", i);
            return ret;
        }
    }
    
    // Wait for subprocesses to start
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Waiting %dms for subprocesses to start...\n",
           MSW_SUBPROCESS_STARTUP_DELAY_MS);
    usleep(MSW_SUBPROCESS_STARTUP_DELAY_MS * 1000);
    
    return 0;
}

static int mswitch_stop_subprocess(AVFormatContext *s, int source_index)
{
    MSwitchDemuxerContext *ctx = s->priv_data;
    MSwitchSource *src = &ctx->sources[source_index];
    int status;
    
    if (!src->subprocess_running || src->subprocess_pid <= 0) {
        return 0;
    }
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Stopping subprocess %d (PID: %d)\n",
           source_index, src->subprocess_pid);
    
    // Send SIGTERM
    kill(src->subprocess_pid, SIGTERM);
    
    // Wait up to 2 seconds for graceful exit
    for (int i = 0; i < 20; i++) {
        if (waitpid(src->subprocess_pid, &status, WNOHANG) == src->subprocess_pid) {
            av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Subprocess %d exited gracefully\n", source_index);
            src->subprocess_running = 0;
            src->subprocess_pid = -1;
            return 0;
        }
        usleep(100000);  // 100ms
    }
    
    // Force kill
    av_log(s, AV_LOG_WARNING, "[MSwitch Demuxer] Force killing subprocess %d\n", source_index);
    kill(src->subprocess_pid, SIGKILL);
    waitpid(src->subprocess_pid, &status, 0);
    
    src->subprocess_running = 0;
    src->subprocess_pid = -1;
    
    return 0;
}

static int mswitch_stop_subprocesses(AVFormatContext *s, MSwitchDemuxerContext *ctx)
{
    int i;
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Stopping all subprocesses...\n");
    
    for (i = 0; i < ctx->num_sources; i++) {
        mswitch_stop_subprocess(s, i);
    }
    
    return 0;
}

static void *mswitch_monitor_thread_func(void *arg)
{
    MSwitchThreadArg *targ = arg;
    MSwitchDemuxerContext *ctx = targ->ctx;
    AVFormatContext *s = targ->s;
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Monitor thread started\n");
    
    while (ctx->monitor_running) {
        int i;
        int status;
        
        for (i = 0; i < ctx->num_sources; i++) {
            MSwitchSource *src = &ctx->sources[i];
            if (src->subprocess_running && src->subprocess_pid > 0) {
                pid_t result = waitpid(src->subprocess_pid, &status, WNOHANG);
                if (result == src->subprocess_pid) {
                    av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] Subprocess %d (PID: %d) died unexpectedly\n",
                           i, src->subprocess_pid);
                    src->subprocess_running = 0;
                    src->subprocess_pid = -1;
                }
            }
        }
        
        sleep(1);
    }
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Monitor thread stopped\n");
    return NULL;
}

// ============================================================================
// UDP Proxy - I-frame Detection
// ============================================================================

/**
 * Detect if packet contains an I-frame (keyframe)
 * Simplified approach: scan entire buffer for H.264 NAL start codes
 * and check for IDR (type 5) or SPS (type 7) NAL units
 */
static int detect_idr_frame_in_mpegts(const uint8_t *buffer, size_t size)
{
    if (size < 10)
        return 0;
    
    // Scan through entire buffer looking for NAL start codes
    // H.264 NAL units start with 0x000001 or 0x00000001
    for (size_t i = 0; i < size - 5; i++) {
        // Look for 3-byte start code (0x000001)
        if (buffer[i] == 0x00 && buffer[i+1] == 0x00 && buffer[i+2] == 0x01) {
            uint8_t nal_header = buffer[i+3];
            int nal_type = nal_header & 0x1F;
            
            // NAL type 5 = IDR (Instantaneous Decoder Refresh) - keyframe
            // NAL type 7 = SPS (Sequence Parameter Set) - usually precedes IDR
            // NAL type 1 = Non-IDR slice (P-frame or B-frame)
            if (nal_type == 5) {
                return 1;  // Found IDR frame
            }
            if (nal_type == 7) {
                // SPS usually comes before IDR, good indicator
                // Continue scanning to see if IDR follows
                for (size_t j = i + 4; j < size - 5 && j < i + 100; j++) {
                    if (buffer[j] == 0x00 && buffer[j+1] == 0x00 && buffer[j+2] == 0x01) {
                        uint8_t next_nal = buffer[j+3];
                        int next_type = next_nal & 0x1F;
                        if (next_type == 5) {
                            return 1;  // Found SPS followed by IDR
                        }
                    }
                }
            }
        }
        // Also check for 4-byte start code (0x00000001)
        else if (i > 0 && buffer[i-1] == 0x00 && buffer[i] == 0x00 && 
                 buffer[i+1] == 0x00 && buffer[i+2] == 0x01) {
            uint8_t nal_header = buffer[i+3];
            int nal_type = nal_header & 0x1F;
            
            if (nal_type == 5) {
                return 1;  // Found IDR frame
            }
        }
    }
    
    return 0;
}

// ============================================================================
// UDP Proxy
// ============================================================================

static void *mswitch_proxy_thread_func(void *arg)
{
    MSwitchThreadArg *targ = arg;
    MSwitchDemuxerContext *ctx = targ->ctx;
    AVFormatContext *s = targ->s;
    struct sockaddr_in dest_addr;
    fd_set readfds;
    struct timeval tv;
    int max_fd;
    uint8_t buffer[MSW_UDP_PACKET_SIZE];
    int i;
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Proxy thread started\n");
    
    // Prepare destination address
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    dest_addr.sin_port = htons(MSW_PROXY_OUTPUT_PORT);
    
    while (ctx->proxy_running) {
        FD_ZERO(&readfds);
        max_fd = -1;
        
        // Add all source sockets to select set
        for (i = 0; i < ctx->num_sources; i++) {
            if (ctx->source_sockets[i] >= 0) {
                FD_SET(ctx->source_sockets[i], &readfds);
                if (ctx->source_sockets[i] > max_fd) {
                    max_fd = ctx->source_sockets[i];
                }
            }
        }
        
        if (max_fd < 0) {
            usleep(100000);  // 100ms
            continue;
        }
        
        tv.tv_sec = 0;
        tv.tv_usec = 100000;  // 100ms timeout
        
        int ret = select(max_fd + 1, &readfds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR)
                continue;
            av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] select() failed: %s\n", strerror(errno));
            break;
        }
        
        if (ret == 0)
            continue;  // Timeout
        
        // Check which socket has data
        for (i = 0; i < ctx->num_sources; i++) {
            if (ctx->source_sockets[i] >= 0 && FD_ISSET(ctx->source_sockets[i], &readfds)) {
                ssize_t bytes_received = recv(ctx->source_sockets[i], buffer, sizeof(buffer), 0);
                
                if (bytes_received > 0) {
                    pthread_mutex_lock(&ctx->state_mutex);
                    int active = ctx->active_source_index;
                    int pending = ctx->pending_source_index;
                    pthread_mutex_unlock(&ctx->state_mutex);
                    
                    // Check for pending switch in seamless mode
                    if (ctx->seamless_mode && pending >= 0 && i == pending) {
                        // Detect I-frame using proper MPEG-TS/H.264 parsing
                        int is_idr_frame = detect_idr_frame_in_mpegts(buffer, bytes_received);
                        
                        av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] 🔍 Checking packet from source %d: size=%zd, is_IDR=%d\n",
                               i, bytes_received, is_idr_frame);
                        
                        if (is_idr_frame) {
                            pthread_mutex_lock(&ctx->state_mutex);
                            ctx->active_source_index = pending;
                            ctx->pending_source_index = -1;
                            active = ctx->active_source_index;
                            pthread_mutex_unlock(&ctx->state_mutex);
                            
                            av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] ⚡ Seamless switch to source %d on IDR frame (keyframe detected)\n", active);
                        } else {
                            static int wait_count = 0;
                            if (wait_count++ % 10 == 0) {
                                av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] ⏳ Waiting for IDR frame from source %d (pending switch, checked %d packets)\n", pending, wait_count);
                            }
                        }
                    }
                    
                    if (i == active) {
                        // Forward packet to output
                        ssize_t bytes_sent = sendto(ctx->output_socket, buffer, bytes_received, 0,
                                                      (struct sockaddr *)&dest_addr, sizeof(dest_addr));
                        if (bytes_sent < 0) {
                            av_log(s, AV_LOG_WARNING, "[MSwitch Demuxer] Failed to forward packet: %s\n",
                                   strerror(errno));
                        } else {
                            static int packet_count = 0;
                            if (packet_count++ % 100 == 0) {
                                av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Forwarded packet from source %d (active=%d, %zd bytes)\n",
                                       i, active, bytes_received);
                            }
                        }
                    } else {
                        static int discard_count = 0;
                        if (discard_count++ % 100 == 0) {
                            av_log(s, AV_LOG_DEBUG, "[MSwitch Demuxer] Discarded packet from source %d (active=%d)\n",
                                   i, active);
                        }
                    }
                }
            }
        }
    }
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Proxy thread stopped\n");
    return NULL;
}

// ============================================================================
// Control Server
// ============================================================================

static void *mswitch_control_thread_func(void *arg)
{
    MSwitchThreadArg *targ = arg;
    MSwitchDemuxerContext *ctx = targ->ctx;
    AVFormatContext *s = targ->s;
    struct sockaddr_in client_addr;
    socklen_t client_len;
    char buffer[1024];
    char response[512];
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Control server thread started on port %d\n", ctx->control_port);
    
    // Set socket to non-blocking for accept
    int flags = fcntl(ctx->control_socket, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(ctx->control_socket, F_SETFL, flags | O_NONBLOCK);
    }
    
    while (ctx->control_running) {
        client_len = sizeof(client_addr);
        int client_fd = accept(ctx->control_socket, (struct sockaddr *)&client_addr, &client_len);
        
        if (client_fd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                usleep(100000);  // 100ms
                continue;
            }
            av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] accept() failed: %s\n", strerror(errno));
            break;
        }
        
        // Read request
        ssize_t bytes_read = read(client_fd, buffer, sizeof(buffer) - 1);
        if (bytes_read > 0) {
            buffer[bytes_read] = '\0';
            
            av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Control request: %s\n", buffer);
            
            // Parse simple commands
            // Expected: POST /switch?source=1 or GET /status
            if (strstr(buffer, "POST /switch")) {
                char *source_param = strstr(buffer, "source=");
                if (source_param) {
                    int new_source = atoi(source_param + 7);
                    
                    if (new_source >= 0 && new_source < ctx->num_sources) {
                        pthread_mutex_lock(&ctx->state_mutex);
                        int old_source = ctx->active_source_index;
                        
                        if (ctx->seamless_mode) {
                            // Seamless: Set pending switch, wait for keyframe
                            ctx->pending_source_index = new_source;
                            pthread_mutex_unlock(&ctx->state_mutex);
                            av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Pending seamless switch: %d → %d (waiting for keyframe)\n",
                                   old_source, new_source);
                        } else if (ctx->cutover_mode) {
                            // Cutover: Immediate switch
                            ctx->active_source_index = new_source;
                            pthread_mutex_unlock(&ctx->state_mutex);
                            av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] ✂️  Cutover switch: %d → %d (immediate)\n",
                                   old_source, new_source);
                        } else {
                            // Graceful: Switch immediately (decoder will resync)
                            ctx->active_source_index = new_source;
                            pthread_mutex_unlock(&ctx->state_mutex);
                            av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] 🔄 Graceful switch: %d → %d (decoder will resync)\n",
                                   old_source, new_source);
                        }
                        
                        snprintf(response, sizeof(response),
                                 "HTTP/1.1 200 OK\r\n"
                                 "Content-Type: application/json\r\n"
                                 "Content-Length: 23\r\n"
                                 "\r\n"
                                 "{\"status\":\"switched\"}");
                    } else {
                        snprintf(response, sizeof(response),
                                 "HTTP/1.1 400 Bad Request\r\n"
                                 "Content-Type: application/json\r\n"
                                 "Content-Length: 30\r\n"
                                 "\r\n"
                                 "{\"error\":\"invalid source\"}");
                    }
                } else {
                    snprintf(response, sizeof(response),
                             "HTTP/1.1 400 Bad Request\r\n"
                             "Content-Type: application/json\r\n"
                             "Content-Length: 31\r\n"
                             "\r\n"
                             "{\"error\":\"missing parameter\"}");
                }
            } else if (strstr(buffer, "GET /status")) {
                pthread_mutex_lock(&ctx->state_mutex);
                int active = ctx->active_source_index;
                pthread_mutex_unlock(&ctx->state_mutex);
                
                char status_body[256];
                snprintf(status_body, sizeof(status_body),
                         "{\"active_source\":%d,\"num_sources\":%d}", active, ctx->num_sources);
                
                snprintf(response, sizeof(response),
                         "HTTP/1.1 200 OK\r\n"
                         "Content-Type: application/json\r\n"
                         "Content-Length: %zu\r\n"
                         "\r\n"
                         "%s", strlen(status_body), status_body);
            } else {
                snprintf(response, sizeof(response),
                         "HTTP/1.1 404 Not Found\r\n"
                         "Content-Type: application/json\r\n"
                         "Content-Length: 23\r\n"
                         "\r\n"
                         "{\"error\":\"not found\"}");
            }
            
            send(client_fd, response, strlen(response), 0);
        }
        
        close(client_fd);
    }
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Control server thread stopped\n");
    return NULL;
}

// ============================================================================
// Demuxer Implementation
// ============================================================================

static int mswitch_read_header(AVFormatContext *s)
{
    MSwitchDemuxerContext *ctx = s->priv_data;
    int ret, i;
    char input_url[256];
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Initializing MSwitch demuxer\n");
    
    // Parse URL
    ret = parse_mswitch_url(s, s->url);
    if (ret < 0) {
        return ret;
    }
    
    // Initialize mutex
    pthread_mutex_init(&ctx->state_mutex, NULL);
    
    // Initialize sockets
    for (i = 0; i < MAX_SOURCES; i++) {
        ctx->source_sockets[i] = -1;
    }
    
    // Create UDP sockets for each source
    for (i = 0; i < ctx->num_sources; i++) {
        ret = mswitch_create_udp_socket(s, ctx->sources[i].source_port, &ctx->source_sockets[i]);
        if (ret < 0) {
            return ret;
        }
    }
    
    // Create output socket (for sending from proxy)
    ctx->output_socket = socket(AF_INET, SOCK_DGRAM, 0);
    if (ctx->output_socket < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] Failed to create output socket: %s\n", strerror(errno));
        return AVERROR(errno);
    }
    
    // No need to bind the output socket, we only send from it
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Created UDP output socket\n");
    
    // Create control socket
    struct sockaddr_in server_addr;
    ctx->control_socket = socket(AF_INET, SOCK_STREAM, 0);
    if (ctx->control_socket < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] Failed to create control socket: %s\n", strerror(errno));
        return AVERROR(errno);
    }
    
    int reuse = 1;
    setsockopt(ctx->control_socket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(ctx->control_port);
    
    if (bind(ctx->control_socket, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] Failed to bind control socket to port %d: %s\n",
               ctx->control_port, strerror(errno));
        close(ctx->control_socket);
        return AVERROR(errno);
    }
    
    if (listen(ctx->control_socket, 5) < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] Failed to listen on control socket: %s\n", strerror(errno));
        close(ctx->control_socket);
        return AVERROR(errno);
    }
    
    // Start subprocesses
    ret = mswitch_start_subprocesses(s, ctx);
    if (ret < 0) {
        return ret;
    }
    
    // Setup thread arguments
    ctx->monitor_arg.s = s;
    ctx->monitor_arg.ctx = ctx;
    ctx->proxy_arg.s = s;
    ctx->proxy_arg.ctx = ctx;
    ctx->control_arg.s = s;
    ctx->control_arg.ctx = ctx;
    
    // Start monitor thread
    ctx->monitor_running = 1;
    pthread_create(&ctx->monitor_thread, NULL, mswitch_monitor_thread_func, &ctx->monitor_arg);
    
    // Start proxy thread
    ctx->proxy_running = 1;
    pthread_create(&ctx->proxy_thread, NULL, mswitch_proxy_thread_func, &ctx->proxy_arg);
    
    // Start control thread
    ctx->control_running = 1;
    pthread_create(&ctx->control_thread, NULL, mswitch_control_thread_func, &ctx->control_arg);
    
    // Open internal input context
    snprintf(input_url, sizeof(input_url), "udp://127.0.0.1:%d", MSW_PROXY_OUTPUT_PORT);
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Opening internal input: %s\n", input_url);
    
    ret = avformat_open_input(&ctx->input_ctx, input_url, NULL, NULL);
    if (ret < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] Failed to open internal input: %s\n", av_err2str(ret));
        return ret;
    }
    
    ret = avformat_find_stream_info(ctx->input_ctx, NULL);
    if (ret < 0) {
        av_log(s, AV_LOG_ERROR, "[MSwitch Demuxer] Failed to find stream info: %s\n", av_err2str(ret));
        return ret;
    }
    
    ctx->input_opened = 1;
    
    // Copy streams from internal context
    for (i = 0; i < ctx->input_ctx->nb_streams; i++) {
        AVStream *in_st = ctx->input_ctx->streams[i];
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
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Initialization complete with %d streams\n", s->nb_streams);
    
    return 0;
}

static int mswitch_read_packet(AVFormatContext *s, AVPacket *pkt)
{
    MSwitchDemuxerContext *ctx = s->priv_data;
    int ret;
    
    if (!ctx->input_opened || !ctx->input_ctx) {
        return AVERROR(EIO);
    }
    
    ret = av_read_frame(ctx->input_ctx, pkt);
    if (ret < 0) {
        return ret;
    }
    
    // Check if source has changed since last packet
    pthread_mutex_lock(&ctx->state_mutex);
    int current_source = ctx->active_source_index;
    int last_source = ctx->last_active_source_index;
    pthread_mutex_unlock(&ctx->state_mutex);
    
    if (current_source != last_source) {
        // Source switched! Mark packet as discontinuity
        pkt->flags |= AV_PKT_FLAG_CORRUPT;  // Force decoder to treat this as a discontinuity
        
        av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] 📡 Source switched %d → %d, marking stream discontinuity\n",
               last_source, current_source);
        
        pthread_mutex_lock(&ctx->state_mutex);
        ctx->last_active_source_index = current_source;
        pthread_mutex_unlock(&ctx->state_mutex);
    }
    
    return ret;
}

static int mswitch_read_close(AVFormatContext *s)
{
    MSwitchDemuxerContext *ctx = s->priv_data;
    int i;
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Closing\n");
    
    // Stop threads
    ctx->control_running = 0;
    ctx->proxy_running = 0;
    ctx->monitor_running = 0;
    
    if (ctx->control_thread) {
        pthread_join(ctx->control_thread, NULL);
    }
    if (ctx->proxy_thread) {
        pthread_join(ctx->proxy_thread, NULL);
    }
    if (ctx->monitor_thread) {
        pthread_join(ctx->monitor_thread, NULL);
    }
    
    // Stop subprocesses
    mswitch_stop_subprocesses(s, ctx);
    
    // Close sockets
    for (i = 0; i < ctx->num_sources; i++) {
        if (ctx->source_sockets[i] >= 0) {
            close(ctx->source_sockets[i]);
        }
    }
    if (ctx->output_socket >= 0) {
        close(ctx->output_socket);
    }
    if (ctx->control_socket >= 0) {
        close(ctx->control_socket);
    }
    
    // Close internal input
    if (ctx->input_opened && ctx->input_ctx) {
        avformat_close_input(&ctx->input_ctx);
    }
    
    // Clean up sources
    for (i = 0; i < ctx->num_sources; i++) {
        av_freep(&ctx->sources[i].url);
        av_freep(&ctx->sources[i].id);
    }
    
    av_freep(&ctx->mode);
    
    pthread_mutex_destroy(&ctx->state_mutex);
    
    av_log(s, AV_LOG_INFO, "[MSwitch Demuxer] Closed\n");
    
    return 0;
}

static const AVClass mswitch_demuxer_class = {
    .class_name = "mswitch demuxer",
    .item_name  = av_default_item_name,
    .version    = LIBAVUTIL_VERSION_INT,
};

const FFInputFormat ff_mswitch_demuxer = {
    .p.name         = "mswitch",
    .p.long_name    = "Multi-Source Switch",
    .p.flags        = AVFMT_NOFILE,
    .p.priv_class   = &mswitch_demuxer_class,
    .priv_data_size = sizeof(MSwitchDemuxerContext),
    .read_header    = mswitch_read_header,
    .read_packet    = mswitch_read_packet,
    .read_close     = mswitch_read_close,
};

