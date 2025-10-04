/*
 * Multi-Source Switch (MSwitch) controller implementation
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 */

#include "ffmpeg_mswitch.h"
#include "ffmpeg.h"
#include "cmdutils.h"
#include "libavutil/avstring.h"
#include "libavutil/opt.h"
#include "libavutil/thread.h"
#include "libavutil/time.h"
#include "libavutil/fifo.h"
#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"
#include "libavutil/parseutils.h"
#include "libavutil/threadmessage.h"
#include "libavfilter/avfilter.h"
#include "libavfilter/buffersrc.h"
#include "libavfilter/buffersink.h"

#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/types.h>

// External global context declared in ffmpeg_opt.c
extern MSwitchContext global_mswitch_ctx;
extern int global_mswitch_enabled;
void *global_mswitch_ctx_ptr = &global_mswitch_ctx;

// Default health thresholds
#define MSW_DEFAULT_STREAM_LOSS_MS 2000
#define MSW_DEFAULT_PID_LOSS_MS 500
#define MSW_DEFAULT_BLACK_MS 800
#define MSW_DEFAULT_CC_ERRORS_PER_SEC 5
#define MSW_DEFAULT_PACKET_LOSS_PERCENT 2.0f
#define MSW_DEFAULT_PACKET_LOSS_WINDOW_SEC 10

// Subprocess management
#define MSW_BASE_UDP_PORT 12350
#define MSW_SUBPROCESS_STARTUP_DELAY_MS 2000
#define MSW_SUBPROCESS_MONITOR_INTERVAL_MS 1000

// UDP Proxy
#define MSW_PROXY_OUTPUT_PORT 12400
#define MSW_UDP_PACKET_SIZE 65536  // Max UDP packet size
#define MSW_PROXY_SELECT_TIMEOUT_MS 100  // Select timeout for proxy thread

// Black frame detection thresholds
#define MSW_BLACK_Y_MEAN_THRESHOLD 16
#define MSW_BLACK_VARIANCE_THRESHOLD 10

static void mswitch_log(MSwitchContext *msw, int level, const char *fmt, ...)
{
    // Simple, safe logging to avoid memory corruption
    va_list args;
    va_start(args, fmt);
    
    // Use a fixed buffer to avoid stack corruption
    char buffer[512];
    int ret = vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    
    if (ret > 0 && ret < sizeof(buffer)) {
        fprintf(stderr, "[MSwitch] %s", buffer);
        fflush(stderr);
    }
}

static int mswitch_parse_sources(MSwitchContext *msw, const char *sources_str)
{
    // Minimal parsing without any logging to avoid corruption
    if (!sources_str) return AVERROR(EINVAL);
    
    char *sources_copy = av_strdup(sources_str);
    if (!sources_copy) return AVERROR(ENOMEM);
    
    char *saveptr = NULL;
    char *token = av_strtok(sources_copy, ";", &saveptr);
    int i = 0;
    
    while (token && i < MSW_MAX_SOURCES) {
        char *eq_pos = strchr(token, '=');
        if (eq_pos) {
            *eq_pos = '\0';
            msw->sources[i].id = av_strdup(token);
            msw->sources[i].url = av_strdup(eq_pos + 1);
            msw->sources[i].name = av_strdup(token);
            
            // Initialize basic fields only
            msw->sources[i].is_healthy = 1;
            msw->sources[i].thread_running = 0;
            msw->sources[i].last_recovery_time = av_gettime() / 1000; // Initialize to current time
            pthread_mutex_init(&msw->sources[i].mutex, NULL);
            pthread_cond_init(&msw->sources[i].cond, NULL);
            
            i++;
        }
        token = av_strtok(NULL, ";", &saveptr);
    }
    
    msw->nb_sources = i;
    av_free(sources_copy);
    
    return (i == 0) ? AVERROR(EINVAL) : 0;
}

static int mswitch_parse_health_thresholds(MSwitchContext *msw, const char *thresholds_str)
{
    char *thresholds_copy = av_strdup(thresholds_str);
    char *saveptr = NULL;
    char *token;
    
    if (!thresholds_copy) {
        return AVERROR(ENOMEM);
    }
    
    // Initialize with defaults
    msw->auto_failover.thresholds.stream_loss_ms = MSW_DEFAULT_STREAM_LOSS_MS;
    msw->auto_failover.thresholds.pid_loss_ms = MSW_DEFAULT_PID_LOSS_MS;
    msw->auto_failover.thresholds.black_ms = MSW_DEFAULT_BLACK_MS;
    msw->auto_failover.thresholds.cc_errors_per_sec = MSW_DEFAULT_CC_ERRORS_PER_SEC;
    msw->auto_failover.thresholds.packet_loss_percent = MSW_DEFAULT_PACKET_LOSS_PERCENT;
    msw->auto_failover.thresholds.packet_loss_window_sec = MSW_DEFAULT_PACKET_LOSS_WINDOW_SEC;
    
    token = av_strtok(thresholds_copy, ",", &saveptr);
    while (token) {
        char *eq_pos = strchr(token, '=');
        if (eq_pos) {
            *eq_pos = '\0';
            int value = atoi(eq_pos + 1);
            
            if (strcmp(token, "stream_loss") == 0) {
                msw->auto_failover.thresholds.stream_loss_ms = value;
            } else if (strcmp(token, "pid_loss") == 0) {
                msw->auto_failover.thresholds.pid_loss_ms = value;
            } else if (strcmp(token, "black_ms") == 0) {
                msw->auto_failover.thresholds.black_ms = value;
            } else if (strcmp(token, "cc_errors_per_sec") == 0) {
                msw->auto_failover.thresholds.cc_errors_per_sec = value;
            } else if (strcmp(token, "packet_loss_percent") == 0) {
                msw->auto_failover.thresholds.packet_loss_percent = (float)value;
            } else if (strcmp(token, "packet_loss_window_sec") == 0) {
                msw->auto_failover.thresholds.packet_loss_window_sec = value;
            }
        }
        token = av_strtok(NULL, ",", &saveptr);
    }
    
    av_free(thresholds_copy);
    return 0;
}

/**
 * NATIVE MSWITCH IMPLEMENTATION
 * 
 * This implementation uses FFmpeg's native pipeline architecture:
 * - Sources are provided as regular -i inputs on the command line
 * - Each input has its own demuxer and decoder threads
 * - Frame-level switching happens in sch_dec_send (ffmpeg_sched.c)
 * - MSwitch just manages the active_source_index
 * 
 * No subprocesses, no external UDP proxies, no pipe feeding.
 * Clean, simple, and uses FFmpeg's existing scheduler infrastructure.
 */

#if 0  // BEGIN DEPRECATED CODE - Kept for reference but not compiled
// DEPRECATED: Subprocess management removed in favor of native pipeline
static int mswitch_start_source_subprocess_seamless(MSwitchContext *msw, int source_index)
{
    // For seamless mode: Create subprocess that outputs compressed packets via UDP
    MSwitchSource *src = &msw->sources[source_index];
    int stdout_pipe[2], stderr_pipe[2];
    char *ffmpeg_args[32];
    int arg_count = 0;
    
    if (src->subprocess_running) {
        mswitch_log(msw, AV_LOG_WARNING, "Source %d subprocess already running\n", source_index);
        return 0;
    }
    
    // Create pipes for subprocess communication
    if (pipe(stdout_pipe) < 0 || pipe(stderr_pipe) < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to create pipes for source %d subprocess\n", source_index);
        return AVERROR(errno);
    }
    
    // Generate UDP output URL for this source (seamless mode uses UDP)
    int udp_port = msw->base_udp_port + source_index;
    char *udp_url = av_asprintf("udp://127.0.0.1:%d", udp_port);
    
    mswitch_log(msw, AV_LOG_INFO, "Starting seamless subprocess for source %d (%s) -> %s\n", 
                source_index, src->url, udp_url);
    
    // Build FFmpeg command for seamless mode (compressed output)
    ffmpeg_args[arg_count++] = "ffmpeg";
    ffmpeg_args[arg_count++] = "-loglevel";
    ffmpeg_args[arg_count++] = "warning";
    ffmpeg_args[arg_count++] = "-re";
    
    // Input specification
    if (strncmp(src->url, "color=", 6) == 0) {
        ffmpeg_args[arg_count++] = "-f";
        ffmpeg_args[arg_count++] = "lavfi";
        ffmpeg_args[arg_count++] = "-i";
        ffmpeg_args[arg_count++] = av_asprintf("%s:size=320x240:rate=5", src->url);
    } else {
        ffmpeg_args[arg_count++] = "-i"; 
        ffmpeg_args[arg_count++] = src->url;
    }
    
    // Output specification - compressed stream for seamless switching
    ffmpeg_args[arg_count++] = "-c:v";
    ffmpeg_args[arg_count++] = "libx264";
    ffmpeg_args[arg_count++] = "-preset";
    ffmpeg_args[arg_count++] = "ultrafast";
    ffmpeg_args[arg_count++] = "-tune";
    ffmpeg_args[arg_count++] = "zerolatency";
    ffmpeg_args[arg_count++] = "-g";
    ffmpeg_args[arg_count++] = "50";
    ffmpeg_args[arg_count++] = "-pix_fmt";
    ffmpeg_args[arg_count++] = "yuv420p";
    ffmpeg_args[arg_count++] = "-f";
    ffmpeg_args[arg_count++] = "mpegts";
    ffmpeg_args[arg_count++] = udp_url;
    ffmpeg_args[arg_count] = NULL;
    
    // Fork subprocess
    src->subprocess_pid = fork();
    if (src->subprocess_pid < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to fork subprocess for source %d\n", source_index);
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        av_free(udp_url);
        return AVERROR(errno);
    }
    
    if (src->subprocess_pid == 0) {
        // Child process - execute FFmpeg
        close(stdout_pipe[0]); // Close read end
        close(stderr_pipe[0]); // Close read end
        
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);
        
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);
        
        execvp("ffmpeg", ffmpeg_args);
        exit(1); // If execvp fails
    }
    
    // Parent process - store pipe file descriptors
    close(stdout_pipe[1]); // Close write end
    close(stderr_pipe[1]); // Close write end
    
    src->subprocess_stdout = stdout_pipe[0];
    src->subprocess_stderr = stderr_pipe[0];
    src->subprocess_running = 1;
    
    av_free(udp_url);
    mswitch_log(msw, AV_LOG_INFO, "Started seamless subprocess %d for source %d\n", 
                src->subprocess_pid, source_index);
    
    return 0;
}

static int mswitch_start_source_subprocess_frame(MSwitchContext *msw, int source_index)
{
    // For graceful/cutover mode: Create subprocess that outputs raw frames via pipe
    MSwitchSource *src = &msw->sources[source_index];
    int frame_pipe[2], stderr_pipe[2];
    char *ffmpeg_args[32];
    int arg_count = 0;
    
    if (src->subprocess_running) {
        mswitch_log(msw, AV_LOG_WARNING, "Source %d subprocess already running\n", source_index);
        return 0;
    }
    
    // Create pipes for subprocess communication
    if (pipe(frame_pipe) < 0 || pipe(stderr_pipe) < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to create pipes for source %d subprocess\n", source_index);
        return AVERROR(errno);
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Starting frame subprocess for source %d (%s)\n", 
                source_index, src->url);
    
    // Build FFmpeg command for frame mode (raw output)
    ffmpeg_args[arg_count++] = "ffmpeg";
    ffmpeg_args[arg_count++] = "-loglevel";
    ffmpeg_args[arg_count++] = "warning";
    ffmpeg_args[arg_count++] = "-re";
    
    // Input specification
    if (strncmp(src->url, "color=", 6) == 0) {
        // Full color specification (e.g., "color=red:size=320x240:rate=5")
        ffmpeg_args[arg_count++] = "-f";
        ffmpeg_args[arg_count++] = "lavfi";
        ffmpeg_args[arg_count++] = "-i";
        ffmpeg_args[arg_count++] = av_asprintf("%s:size=320x240:rate=5", src->url);
    } else if (strcmp(src->url, "red") == 0 || strcmp(src->url, "green") == 0 || 
               strcmp(src->url, "blue") == 0 || strcmp(src->url, "yellow") == 0 ||
               strcmp(src->url, "black") == 0 || strcmp(src->url, "white") == 0) {
        // Simple color names - convert to lavfi color generator
        ffmpeg_args[arg_count++] = "-f";
        ffmpeg_args[arg_count++] = "lavfi";
        ffmpeg_args[arg_count++] = "-i";
        ffmpeg_args[arg_count++] = av_asprintf("color=%s:size=320x240:rate=5", src->url);
    } else {
        // Regular file or URL input
        ffmpeg_args[arg_count++] = "-i"; 
        ffmpeg_args[arg_count++] = src->url;
    }
    
    // Output specification - raw frames for frame-level switching
    ffmpeg_args[arg_count++] = "-f";
    ffmpeg_args[arg_count++] = "rawvideo";
    ffmpeg_args[arg_count++] = "-pix_fmt";
    ffmpeg_args[arg_count++] = "yuv420p";
    ffmpeg_args[arg_count++] = "pipe:1"; // Output to stdout
    ffmpeg_args[arg_count] = NULL;
    
    // Fork subprocess
    src->subprocess_pid = fork();
    if (src->subprocess_pid < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to fork subprocess for source %d\n", source_index);
        close(frame_pipe[0]); close(frame_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        return AVERROR(errno);
    }
    
    if (src->subprocess_pid == 0) {
        // Child process - execute FFmpeg
        close(frame_pipe[0]); // Close read end
        close(stderr_pipe[0]); // Close read end
        
        dup2(frame_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);
        
        close(frame_pipe[1]);
        close(stderr_pipe[1]);
        
        execvp("ffmpeg", ffmpeg_args);
        exit(1); // If execvp fails
    }
    
    // Parent process - store pipe file descriptors
    close(frame_pipe[1]); // Close write end
    close(stderr_pipe[1]); // Close write end
    
    src->frame_pipe_fd = frame_pipe[0];   // Raw frame data pipe
    src->subprocess_stderr = stderr_pipe[0];
    src->subprocess_running = 1;
    
    // Initialize frame mutex
    pthread_mutex_init(&src->frame_mutex, NULL);
    
    mswitch_log(msw, AV_LOG_INFO, "Started frame subprocess %d for source %d\n", 
                src->subprocess_pid, source_index);
    
    return 0;
}

// Unified subprocess starter that chooses mode based on MSwitch configuration
static int mswitch_start_source_subprocess(MSwitchContext *msw, int source_index)
{
    if (msw->mode == MSW_MODE_SEAMLESS) {
        return mswitch_start_source_subprocess_seamless(msw, source_index);
    } else {
        // Graceful and cutover modes use frame-level switching
        return mswitch_start_source_subprocess_frame(msw, source_index);
    }
}

static int mswitch_stop_source_subprocess(MSwitchContext *msw, int source_index)
{
    MSwitchSource *src = &msw->sources[source_index];
    
    if (!src->subprocess_running) {
        return 0;
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Stopping subprocess %d for source %d\n", 
                src->subprocess_pid, source_index);
    
    // Send SIGTERM to subprocess
    kill(src->subprocess_pid, SIGTERM);
    
    // Wait for process to terminate (with timeout)
    int status;
    int wait_result = waitpid(src->subprocess_pid, &status, WNOHANG);
    if (wait_result == 0) {
        // Process still running, wait a bit then force kill
        usleep(500000); // 500ms
        wait_result = waitpid(src->subprocess_pid, &status, WNOHANG);
        if (wait_result == 0) {
            mswitch_log(msw, AV_LOG_WARNING, "Force killing subprocess %d\n", src->subprocess_pid);
            kill(src->subprocess_pid, SIGKILL);
            waitpid(src->subprocess_pid, &status, 0);
        }
    }
    
    // Close pipes
    if (src->subprocess_stdout >= 0) {
        close(src->subprocess_stdout);
        src->subprocess_stdout = -1;
    }
    if (src->subprocess_stderr >= 0) {
        close(src->subprocess_stderr);
        src->subprocess_stderr = -1;
    }
    if (src->frame_pipe_fd >= 0) {
        close(src->frame_pipe_fd);
        src->frame_pipe_fd = -1;
    }
    
    // Cleanup frame mutex if initialized
    if (src->subprocess_running) {
        pthread_mutex_destroy(&src->frame_mutex);
    }
    
    src->subprocess_running = 0;
    src->subprocess_pid = 0;
    
    return 0;
}

// Frame feeding thread for graceful/cutover modes (DEPRECATED - needs proper FFmpeg integration)
static void *mswitch_frame_feeder_thread(void *arg)
{
    MSwitchContext *msw = (MSwitchContext *)arg;
    
    mswitch_log(msw, AV_LOG_WARNING, "Frame-level switching not yet implemented - requires deeper FFmpeg integration\n");
    mswitch_log(msw, AV_LOG_WARNING, "Please use seamless mode with UDP streams for now\n");
    
    return NULL;
}

// DEPRECATED: UDP forwarder not needed in native mode
#if 0
static void *mswitch_udp_forwarder_thread(void *arg)
{
    MSwitchContext *msw = (MSwitchContext *)arg;
    int source_sockets[MSW_MAX_SOURCES];
    int output_socket = -1;
    struct sockaddr_in output_addr;
    char buffer[65536]; // Max UDP packet size
    fd_set read_fds;
    struct timeval tv;
    int max_fd = 0;
    
    mswitch_log(msw, AV_LOG_INFO, "UDP forwarder thread started\n");
    
    // Create listening sockets for each source
    for (int i = 0; i < msw->nb_sources; i++) {
        MSwitchSource *src = &msw->sources[i];
        
        if (!src->subprocess_running || src->subprocess_output_url == NULL) {
            source_sockets[i] = -1;
            continue;
        }
        
        // Parse UDP port from URL (format: udp://127.0.0.1:PORT)
        int port = msw->base_udp_port + i;
        
        source_sockets[i] = socket(AF_INET, SOCK_DGRAM, 0);
        if (source_sockets[i] < 0) {
            mswitch_log(msw, AV_LOG_ERROR, "Failed to create socket for source %d: %s\n", i, strerror(errno));
            continue;
        }
        
        // Set socket to non-blocking and allow reuse
        int flags = fcntl(source_sockets[i], F_GETFL, 0);
        fcntl(source_sockets[i], F_SETFL, flags | O_NONBLOCK);
        
        int reuse = 1;
        setsockopt(source_sockets[i], SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        
        // Bind to source port
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons(port);
        
        if (bind(source_sockets[i], (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            mswitch_log(msw, AV_LOG_ERROR, "Failed to bind source %d socket to port %d: %s\n", 
                       i, port, strerror(errno));
            close(source_sockets[i]);
            source_sockets[i] = -1;
            continue;
        }
        
        mswitch_log(msw, AV_LOG_INFO, "Listening for source %d on UDP port %d\n", i, port);
        
        if (source_sockets[i] > max_fd) {
            max_fd = source_sockets[i];
        }
    }
    
    // Create output socket for forwarding
    output_socket = socket(AF_INET, SOCK_DGRAM, 0);
    if (output_socket < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to create output socket: %s\n", strerror(errno));
        goto cleanup;
    }
    
    // Configure output address (forward to main FFmpeg input)
    memset(&output_addr, 0, sizeof(output_addr));
    output_addr.sin_family = AF_INET;
    output_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    output_addr.sin_port = htons(msw->base_udp_port + 1000); // Output port: base + 1000
    
    mswitch_log(msw, AV_LOG_INFO, "Forwarding to UDP port %d\n", msw->base_udp_port + 1000);
    
    // Main forwarding loop
    while (msw->enable && msw->packet_switching_enabled) {
        FD_ZERO(&read_fds);
        
        // Add all source sockets to the fd_set
        for (int i = 0; i < msw->nb_sources; i++) {
            if (source_sockets[i] >= 0) {
                FD_SET(source_sockets[i], &read_fds);
            }
        }
        
        // Wait for data with timeout
        tv.tv_sec = 0;
        tv.tv_usec = 100000; // 100ms timeout
        
        int activity = select(max_fd + 1, &read_fds, NULL, NULL, &tv);
        
        if (activity < 0) {
            if (errno != EINTR) {
                mswitch_log(msw, AV_LOG_ERROR, "Select error: %s\n", strerror(errno));
            }
            continue;
        }
        
        if (activity == 0) {
            // Timeout, check if still enabled
            continue;
        }
        
        // Check which sockets have data
        for (int i = 0; i < msw->nb_sources; i++) {
            if (source_sockets[i] < 0 || !FD_ISSET(source_sockets[i], &read_fds)) {
                continue;
            }
            
            // Receive packet from source
            ssize_t recv_len = recv(source_sockets[i], buffer, sizeof(buffer), 0);
            
            if (recv_len < 0) {
                if (errno != EAGAIN && errno != EWOULDBLOCK) {
                    mswitch_log(msw, AV_LOG_ERROR, "Recv error from source %d: %s\n", 
                               i, strerror(errno));
                }
                continue;
            }
            
            // Only forward if this is the active source
            if (i == msw->active_source_index) {
                ssize_t sent = sendto(output_socket, buffer, recv_len, 0,
                                     (struct sockaddr *)&output_addr, sizeof(output_addr));
                
                if (sent < 0) {
                    mswitch_log(msw, AV_LOG_ERROR, "Send error: %s\n", strerror(errno));
                } else {
                    // Periodic debug logging
                    static int packet_count = 0;
                    if (packet_count++ % 100 == 0) {
                        mswitch_log(msw, AV_LOG_DEBUG, "Forwarded %zd bytes from source %d\n", 
                                   sent, i);
                    }
                }
            }
        }
    }
    
cleanup:
    // Close all sockets
    for (int i = 0; i < msw->nb_sources; i++) {
        if (source_sockets[i] >= 0) {
            close(source_sockets[i]);
        }
    }
    
    if (output_socket >= 0) {
        close(output_socket);
    }
    
    mswitch_log(msw, AV_LOG_INFO, "UDP forwarder thread stopped\n");
    return NULL;
}
#endif  // 0 - END UDP forwarder
#endif  // 0 - END DEPRECATED CODE

// ============================================================================
// SUBPROCESS MANAGEMENT (Multi-Process Architecture)
// ============================================================================

/**
 * Build FFmpeg command for subprocess based on source URL and mode
 */
static char* mswitch_build_subprocess_command(MSwitchContext *msw, int source_index)
{
    MSwitchSource *src = &msw->sources[source_index];
    char *cmd = NULL;
    int udp_port = MSW_BASE_UDP_PORT + source_index;
    
    // Determine codec settings based on mode
    const char *codec_opts;
    if (msw->mode == MSW_MODE_SEAMLESS) {
        // Seamless mode: copy codecs (no transcoding)
        codec_opts = "-c:v copy -c:a copy";
    } else {
        // Graceful/Cutover modes: transcode to common format
        codec_opts = "-c:v libx264 -preset ultrafast -tune zerolatency -g 50 -pix_fmt yuv420p -c:a aac -b:a 128k";
    }
    
    // Build command: ffmpeg -i {source} {codecs} -f mpegts udp://127.0.0.1:{port}
    int cmd_len = snprintf(NULL, 0, 
                          "ffmpeg -nostdin -i \"%s\" %s -f mpegts \"udp://127.0.0.1:%d\"",
                          src->url, codec_opts, udp_port);
    
    cmd = av_malloc(cmd_len + 1);
    if (!cmd) {
        return NULL;
    }
    
    snprintf(cmd, cmd_len + 1,
            "ffmpeg -nostdin -i \"%s\" %s -f mpegts \"udp://127.0.0.1:%d\"",
            src->url, codec_opts, udp_port);
    
    mswitch_log(msw, AV_LOG_INFO, "[Subprocess %d] Command: %s\n", source_index, cmd);
    
    return cmd;
}

/**
 * Start FFmpeg subprocess for a source
 */
static int mswitch_start_source_subprocess(MSwitchContext *msw, int source_index)
{
    MSwitchSource *src = &msw->sources[source_index];
    
    if (src->subprocess_running) {
        mswitch_log(msw, AV_LOG_WARNING, "[Subprocess %d] Already running (PID: %d)\n", 
                   source_index, (int)src->subprocess_pid);
        return 0;
    }
    
    // Build subprocess command
    char *cmd = mswitch_build_subprocess_command(msw, source_index);
    if (!cmd) {
        mswitch_log(msw, AV_LOG_ERROR, "[Subprocess %d] Failed to build command\n", source_index);
        return AVERROR(ENOMEM);
    }
    
    mswitch_log(msw, AV_LOG_INFO, "[Subprocess %d] Starting subprocess for source %s\n", 
               source_index, src->id);
    
    // Fork and exec
    pid_t pid = fork();
    
    if (pid < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "[Subprocess %d] Fork failed: %s\n", 
                   source_index, strerror(errno));
        av_free(cmd);
        return AVERROR(errno);
    }
    
    if (pid == 0) {
        // Child process: exec FFmpeg
        // Redirect stderr to /dev/null to avoid cluttering output
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }
        
        // Execute command via shell
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        
        // If exec fails, exit immediately
        _exit(1);
    }
    
    // Parent process: store PID and mark as running
    src->subprocess_pid = pid;
    src->subprocess_running = 1;
    src->subprocess_output_url = av_asprintf("udp://127.0.0.1:%d", MSW_BASE_UDP_PORT + source_index);
    
    mswitch_log(msw, AV_LOG_INFO, "[Subprocess %d] Started (PID: %d, URL: %s)\n", 
               source_index, (int)pid, src->subprocess_output_url);
    
    av_free(cmd);
    
    return 0;
}

/**
 * Stop FFmpeg subprocess for a source
 */
static int mswitch_stop_source_subprocess(MSwitchContext *msw, int source_index)
{
    MSwitchSource *src = &msw->sources[source_index];
    
    if (!src->subprocess_running) {
        return 0;
    }
    
    mswitch_log(msw, AV_LOG_INFO, "[Subprocess %d] Stopping subprocess (PID: %d)\n", 
               source_index, (int)src->subprocess_pid);
    
    // Send SIGTERM for graceful shutdown
    if (kill(src->subprocess_pid, SIGTERM) == 0) {
        // Wait up to 2 seconds for process to exit
        int wait_count = 0;
        while (wait_count < 20) {
            int status;
            pid_t result = waitpid(src->subprocess_pid, &status, WNOHANG);
            
            if (result == src->subprocess_pid) {
                // Process exited
                mswitch_log(msw, AV_LOG_INFO, "[Subprocess %d] Exited gracefully\n", source_index);
                break;
            } else if (result < 0) {
                // Error or already exited
                break;
            }
            
            usleep(100000); // 100ms
            wait_count++;
        }
        
        // If still running, send SIGKILL
        if (wait_count >= 20) {
            mswitch_log(msw, AV_LOG_WARNING, "[Subprocess %d] Forcing kill...\n", source_index);
            kill(src->subprocess_pid, SIGKILL);
            waitpid(src->subprocess_pid, NULL, 0);
        }
    }
    
    src->subprocess_running = 0;
    src->subprocess_pid = 0;
    
    if (src->subprocess_output_url) {
        av_free(src->subprocess_output_url);
        src->subprocess_output_url = NULL;
    }
    
    return 0;
}

/**
 * Monitor subprocess health (checks if process is still running)
 */
static void* mswitch_monitor_subprocess_thread(void *arg)
{
    MSwitchContext *msw = (MSwitchContext *)arg;
    
    mswitch_log(msw, AV_LOG_INFO, "Subprocess monitor thread started\n");
    
    while (msw->health_running) {
        // Check each subprocess
        for (int i = 0; i < msw->nb_sources; i++) {
            MSwitchSource *src = &msw->sources[i];
            
            if (src->subprocess_running) {
                // Check if process is still alive
                int status;
                pid_t result = waitpid(src->subprocess_pid, &status, WNOHANG);
                
                if (result == src->subprocess_pid) {
                    // Process exited
                    mswitch_log(msw, AV_LOG_ERROR, "[Subprocess %d] Process died unexpectedly (PID: %d)\n", 
                               i, (int)src->subprocess_pid);
                    
                    src->subprocess_running = 0;
                    src->subprocess_pid = 0;
                    
                    // TODO: Implement automatic restart if configured
                    // For now, just mark as failed
                }
            }
        }
        
        // Sleep for monitoring interval
        usleep(MSW_SUBPROCESS_MONITOR_INTERVAL_MS * 1000);
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Subprocess monitor thread stopped\n");
    return NULL;
}

// ============================================================================
// UDP PROXY (Phase 2)
// ============================================================================

/**
 * Create and configure a UDP socket
 */
static int mswitch_create_udp_socket(MSwitchContext *msw, int port, int *sock_fd)
{
    int sock;
    struct sockaddr_in addr;
    int reuse = 1;
    
    // Create socket
    sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "[UDP Proxy] Failed to create socket for port %d: %s\n", 
                   port, strerror(errno));
        return AVERROR(errno);
    }
    
    // Set socket options
    if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) < 0) {
        mswitch_log(msw, AV_LOG_WARNING, "[UDP Proxy] Failed to set SO_REUSEADDR: %s\n", 
                   strerror(errno));
    }
    
    // Set non-blocking mode
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags < 0 || fcntl(sock, F_SETFL, flags | O_NONBLOCK) < 0) {
        mswitch_log(msw, AV_LOG_WARNING, "[UDP Proxy] Failed to set non-blocking mode: %s\n", 
                   strerror(errno));
    }
    
    // Bind to port
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr.sin_port = htons(port);
    
    if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "[UDP Proxy] Failed to bind to port %d: %s\n", 
                   port, strerror(errno));
        close(sock);
        return AVERROR(errno);
    }
    
    mswitch_log(msw, AV_LOG_INFO, "[UDP Proxy] Socket bound to 127.0.0.1:%d\n", port);
    
    *sock_fd = sock;
    return 0;
}

/**
 * UDP Proxy Thread - Forwards packets from active subprocess to output
 */
static void* mswitch_udp_proxy_thread(void *arg)
{
    MSwitchContext *msw = (MSwitchContext *)arg;
    int source_sockets[MSW_MAX_SOURCES];
    int output_socket = -1;
    struct sockaddr_in output_addr;
    uint8_t buffer[MSW_UDP_PACKET_SIZE];
    fd_set read_fds;
    struct timeval tv;
    int max_fd = -1;
    int ret;
    
    mswitch_log(msw, AV_LOG_INFO, "[UDP Proxy] Starting UDP proxy thread\n");
    
    // Initialize all source sockets to -1
    for (int i = 0; i < MSW_MAX_SOURCES; i++) {
        source_sockets[i] = -1;
    }
    
    // Create input sockets for each source (listen on subprocess output ports)
    for (int i = 0; i < msw->nb_sources; i++) {
        int port = MSW_BASE_UDP_PORT + i;
        ret = mswitch_create_udp_socket(msw, port, &source_sockets[i]);
        if (ret < 0) {
            mswitch_log(msw, AV_LOG_ERROR, "[UDP Proxy] Failed to create socket for source %d\n", i);
            goto cleanup;
        }
        
        if (source_sockets[i] > max_fd) {
            max_fd = source_sockets[i];
        }
    }
    
    // Create output socket (forward to proxy output port)
    output_socket = socket(AF_INET, SOCK_DGRAM, 0);
    if (output_socket < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "[UDP Proxy] Failed to create output socket: %s\n", 
                   strerror(errno));
        goto cleanup;
    }
    
    // Configure output address
    memset(&output_addr, 0, sizeof(output_addr));
    output_addr.sin_family = AF_INET;
    output_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    output_addr.sin_port = htons(MSW_PROXY_OUTPUT_PORT);
    
    mswitch_log(msw, AV_LOG_INFO, "[UDP Proxy] Forwarding to 127.0.0.1:%d\n", MSW_PROXY_OUTPUT_PORT);
    mswitch_log(msw, AV_LOG_INFO, "[UDP Proxy] Proxy thread running\n");
    
    // Main proxy loop
    while (msw->health_running) {
        // Set up select() with timeout
        FD_ZERO(&read_fds);
        for (int i = 0; i < msw->nb_sources; i++) {
            if (source_sockets[i] >= 0) {
                FD_SET(source_sockets[i], &read_fds);
            }
        }
        
        tv.tv_sec = 0;
        tv.tv_usec = MSW_PROXY_SELECT_TIMEOUT_MS * 1000;
        
        ret = select(max_fd + 1, &read_fds, NULL, NULL, &tv);
        
        if (ret < 0) {
            if (errno == EINTR) {
                continue;  // Interrupted by signal, retry
            }
            mswitch_log(msw, AV_LOG_ERROR, "[UDP Proxy] select() failed: %s\n", strerror(errno));
            break;
        }
        
        if (ret == 0) {
            // Timeout, no data available
            continue;
        }
        
        // Check which sockets have data
        for (int i = 0; i < msw->nb_sources; i++) {
            if (source_sockets[i] < 0 || !FD_ISSET(source_sockets[i], &read_fds)) {
                continue;
            }
            
            // Read packet from this source
            ssize_t bytes_read = recv(source_sockets[i], buffer, sizeof(buffer), 0);
            
            if (bytes_read < 0) {
                if (errno != EAGAIN && errno != EWOULDBLOCK) {
                    mswitch_log(msw, AV_LOG_WARNING, "[UDP Proxy] recv() from source %d failed: %s\n", 
                               i, strerror(errno));
                }
                continue;
            }
            
            if (bytes_read == 0) {
                continue;  // No data
            }
            
            // Get current active source (with mutex protection)
            pthread_mutex_lock(&msw->state_mutex);
            int active = msw->active_source_index;
            pthread_mutex_unlock(&msw->state_mutex);
            
            // Forward only if this is the active source
            if (i == active) {
                ssize_t bytes_sent = sendto(output_socket, buffer, bytes_read, 0,
                                           (struct sockaddr*)&output_addr, sizeof(output_addr));
                
                if (bytes_sent < 0) {
                    mswitch_log(msw, AV_LOG_WARNING, "[UDP Proxy] sendto() failed: %s\n", 
                               strerror(errno));
                } else if (bytes_sent != bytes_read) {
                    mswitch_log(msw, AV_LOG_WARNING, "[UDP Proxy] Partial send: %zd/%zd bytes\n", 
                               bytes_sent, bytes_read);
                }
                // Successfully forwarded packet from active source
            } else {
                // Discard packet from inactive source (silently)
            }
        }
    }
    
cleanup:
    mswitch_log(msw, AV_LOG_INFO, "[UDP Proxy] Cleaning up proxy thread\n");
    
    // Close all source sockets
    for (int i = 0; i < msw->nb_sources; i++) {
        if (source_sockets[i] >= 0) {
            close(source_sockets[i]);
        }
    }
    
    // Close output socket
    if (output_socket >= 0) {
        close(output_socket);
    }
    
    mswitch_log(msw, AV_LOG_INFO, "[UDP Proxy] Proxy thread stopped\n");
    return NULL;
}

/**
 * NATIVE MSWITCH INITIALIZATION
 * 
 * In native mode, MSwitch does NOT start subprocesses. Instead:
 * 1. Sources are parsed from -msw.sources to get IDs
 * 2. Actual inputs come from -i flags on command line
 * 3. FFmpeg's scheduler handles all demuxing/decoding in parallel
 * 4. MSwitch just controls which decoder frames pass through
 * 5. Switching happens in sch_dec_send (ffmpeg_sched.c)
 */
int mswitch_init(MSwitchContext *msw, OptionsContext *o)
{
    int ret = 0;
    
    mswitch_log(msw, AV_LOG_INFO, "Initializing native MSwitch...\n");
    
    // Initialize only the runtime fields, preserving option fields from command-line parsing
    msw->active_source_index = 0;
    msw->last_switch_time = 0;
    msw->switching = 0;
    msw->metrics_enable = 0;
    msw->json_metrics = 0;
    msw->enable = 1;  // Enable MSwitch operation
    
    // Initialize the sources array
    memset(msw->sources, 0, sizeof(msw->sources));
    msw->nb_sources = 0;
    
    // Initialize mutexes and conditions
    pthread_mutex_init(&msw->state_mutex, NULL);
    pthread_cond_init(&msw->switch_cond, NULL);
    
    // Initialize threading fields
    msw->health_running = 0;
    memset(&msw->health_thread, 0, sizeof(msw->health_thread));
    msw->metrics_file = NULL;
    
    // Parse sources from the global context
    if (global_mswitch_ctx.sources_str && strlen(global_mswitch_ctx.sources_str) > 0) {
        mswitch_log(msw, AV_LOG_INFO, "Parsing sources: %s\n", global_mswitch_ctx.sources_str);
        ret = mswitch_parse_sources(msw, global_mswitch_ctx.sources_str);
        if (ret < 0) {
            mswitch_log(msw, AV_LOG_ERROR, "Failed to parse sources\n");
            goto cleanup_on_error;
        }
        mswitch_log(msw, AV_LOG_INFO, "Successfully parsed %d sources\n", msw->nb_sources);
    } else {
        mswitch_log(msw, AV_LOG_ERROR, "No sources specified for MSwitch\n");
        ret = AVERROR(EINVAL);
        goto cleanup_on_error;
    }
    
    // Set values from global context
    msw->ingest_mode = global_mswitch_ctx.ingest_mode_str ? 
                      (strcmp(global_mswitch_ctx.ingest_mode_str, "standby") == 0 ? MSW_INGEST_STANDBY : MSW_INGEST_HOT) : 
                      MSW_INGEST_HOT;
    
    // Parse mode 
    if (global_mswitch_ctx.mode_str) {
        if (strcmp(global_mswitch_ctx.mode_str, "seamless") == 0) {
            msw->mode = MSW_MODE_SEAMLESS;
        } else if (strcmp(global_mswitch_ctx.mode_str, "cutover") == 0) {
            msw->mode = MSW_MODE_CUTOVER;
        } else if (strcmp(global_mswitch_ctx.mode_str, "graceful") == 0) {
            msw->mode = MSW_MODE_GRACEFUL;
        } else {
            msw->mode = MSW_MODE_GRACEFUL; // default
        }
    } else {
        msw->mode = MSW_MODE_GRACEFUL;
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Configuration: mode=%s, ingest=%s, sources=%d\n", 
                msw->mode == MSW_MODE_SEAMLESS ? "seamless" : 
                msw->mode == MSW_MODE_GRACEFUL ? "graceful" : "cutover",
                msw->ingest_mode == MSW_INGEST_HOT ? "hot" : "standby",
                msw->nb_sources);
    
    mswitch_log(msw, AV_LOG_INFO, "Active source: %d (%s)\n", 
                msw->active_source_index, msw->sources[msw->active_source_index].id);
    
    // Set buffer and timing parameters
    msw->buffer_ms = global_mswitch_ctx.buffer_ms > 0 ? global_mswitch_ctx.buffer_ms : MSW_DEFAULT_BUFFER_MS;
    msw->on_cut = MSW_ON_CUT_FREEZE;
    msw->freeze_on_cut_ms = global_mswitch_ctx.freeze_on_cut_ms > 0 ? global_mswitch_ctx.freeze_on_cut_ms : 2000;
    msw->force_layout = 0;
    
    // Initialize webhook (using global context values)
    msw->webhook.enable = global_mswitch_ctx.webhook.enable;
    msw->webhook.port = global_mswitch_ctx.webhook.port > 0 ? global_mswitch_ctx.webhook.port : 8099;
    if (!msw->webhook.methods) {
        msw->webhook.methods = av_strdup("switch,health,config");
        if (!msw->webhook.methods) {
            ret = AVERROR(ENOMEM);
            goto cleanup_on_error;
        }
    }
    msw->webhook.server_running = 0;

    mswitch_log(msw, AV_LOG_INFO, "Webhook config: enable=%d, port=%d\n", msw->webhook.enable, msw->webhook.port);

    // Initialize command queue
    ret = mswitch_cmd_queue_init(msw);
    if (ret < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to initialize command queue: %d\n", ret);
        goto cleanup_on_error;
    }
    
    // Start webhook server if enabled
    if (msw->webhook.enable) {
        mswitch_log(msw, AV_LOG_INFO, "Starting webhook server on port %d\n", msw->webhook.port);
        ret = mswitch_webhook_start(msw);
        if (ret < 0) {
            mswitch_log(msw, AV_LOG_WARNING, "Failed to start webhook server: %d\n", ret);
            // Don't fail initialization if webhook fails
        }
    }
    
    // Initialize CLI - disable separate thread, use FFmpeg's interactive system
    msw->cli.enable = 0; // Use FFmpeg's built-in interactive commands instead
    msw->cli.cli_running = 0;
    
    // Initialize auto failover
    msw->auto_failover.enable = 0; // Disabled by default, must be explicitly enabled
    msw->auto_failover.health_window_ms = MSW_DEFAULT_HEALTH_WINDOW_MS;
    msw->auto_failover.recovery_delay_ms = 5000; // 5 seconds recovery delay
    
    mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Auto-failover initialized: enable=%d, recovery_delay=%d\n", 
               msw->auto_failover.enable, msw->auto_failover.recovery_delay_ms);
    
    // Check if auto-failover was enabled via command line
    if (msw->auto_failover.enable) {
        mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Auto-failover enabled via command line\n");
    } else {
        mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Auto-failover disabled by default\n");
    }
    msw->auto_failover.failover_count = 0;
    msw->auto_failover.last_failover_time = 0;
    
    // Initialize health thresholds
    msw->auto_failover.thresholds.stream_loss_ms = MSW_DEFAULT_STREAM_LOSS_MS;
    msw->auto_failover.thresholds.pid_loss_ms = MSW_DEFAULT_PID_LOSS_MS;
    msw->auto_failover.thresholds.black_ms = MSW_DEFAULT_BLACK_MS;
    msw->auto_failover.thresholds.cc_errors_per_sec = MSW_DEFAULT_CC_ERRORS_PER_SEC;
    msw->auto_failover.thresholds.packet_loss_percent = MSW_DEFAULT_PACKET_LOSS_PERCENT;
    msw->auto_failover.thresholds.packet_loss_window_sec = MSW_DEFAULT_PACKET_LOSS_WINDOW_SEC;
    
    // Initialize revert policy
    msw->revert.policy = MSW_REVERT_AUTO;
    msw->revert.health_window_ms = MSW_DEFAULT_HEALTH_WINDOW_MS;
    
    // Start subprocesses for all sources (multi-process architecture)
    // Skip subprocess creation for lavfi inputs - not needed
    mswitch_log(msw, AV_LOG_INFO, "Skipping subprocess creation for lavfi inputs\n");
    
    // Skip UDP proxy thread for lavfi inputs - not needed
    mswitch_log(msw, AV_LOG_INFO, "Skipping UDP proxy thread for lavfi inputs\n");
    
    // Frame timestamp updates are handled directly by the filter
    
    mswitch_log(msw, AV_LOG_INFO, "MSwitch initialized with %d sources\n", msw->nb_sources);
    mswitch_log(msw, AV_LOG_INFO, "MSwitch proxy listening on ports %d-%d, forwarding to port %d\n",
                MSW_BASE_UDP_PORT, MSW_BASE_UDP_PORT + msw->nb_sources - 1, MSW_PROXY_OUTPUT_PORT);
    mswitch_log(msw, AV_LOG_INFO, "Interactive commands: 0-2 (switch source), m (status), ? (help)\n");
    return 0;

cleanup_on_error:
    // Clean up partially initialized context
    mswitch_cleanup(msw);
    return ret;
}

int mswitch_cleanup(MSwitchContext *msw)
{
    int i;
    
    if (!msw) {
        return 0;
    }
    
    // Stop all threads
    mswitch_stop(msw);
    
    // Stop UDP proxy thread if running
    if (msw->proxy_running && msw->proxy_thread) {
        mswitch_log(msw, AV_LOG_INFO, "Stopping UDP proxy thread\n");
        msw->health_running = 0; // Signal proxy thread to stop (reuses health_running flag)
        pthread_join(msw->proxy_thread, NULL);
        msw->proxy_running = 0;
    }
    
    // Stop frame feeder thread if running
    if (msw->frame_switching_enabled && msw->frame_switch_thread) {
        mswitch_log(msw, AV_LOG_INFO, "Stopping frame feeder thread\n");
        msw->enable = 0; // Signal thread to stop
        pthread_join(msw->frame_switch_thread, NULL);
    }
    
    // Cleanup sources
    for (i = 0; i < msw->nb_sources; i++) {
        MSwitchSource *src = &msw->sources[i];
        
        // Stop subprocess if running
        mswitch_stop_source_subprocess(msw, i);
        
        // Free strings only if they were allocated
        if (src->id) {
            av_freep(&src->id);
        }
        if (src->url) {
            av_freep(&src->url);
        }
        if (src->name) {
            av_freep(&src->name);
        }
        
        // Close format context
        if (src->fmt_ctx) {
            avformat_close_input(&src->fmt_ctx);
        }
        
        // Free packet and frame
        if (src->pkt) {
            av_packet_free(&src->pkt);
        }
        
        if (src->frame) {
            av_frame_free(&src->frame);
        }
        
        // Free FIFOs
        if (src->packet_fifo) {
            av_fifo_freep2(&src->packet_fifo);
        }
        
        if (src->frame_fifo) {
            av_fifo_freep2(&src->frame_fifo);
        }
        
        // Destroy mutex and condition variable - these are always initialized in parse_sources
        pthread_mutex_destroy(&src->mutex);
        pthread_cond_destroy(&src->cond);
    }
    
    // Reset source count
    msw->nb_sources = 0;
    
    // Cleanup webhook
    if (msw->webhook.methods) {
        av_freep(&msw->webhook.methods);
    }
    
    // Cleanup command queue
    mswitch_cmd_queue_cleanup(msw);
    
    // Cleanup main mutexes - these are always initialized in mswitch_init
    pthread_mutex_destroy(&msw->state_mutex);
    pthread_cond_destroy(&msw->switch_cond);
    
    mswitch_log(msw, AV_LOG_INFO, "MSwitch cleanup completed\n");
    return 0;
}

int mswitch_start(MSwitchContext *msw)
{
    int ret = 0;
    
    if (!msw->enable) {
        return 0;
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Starting MSwitch controller\n");
    
    // Start health monitoring thread with optimized settings
    // Disable periodic health monitoring - using immediate duplicate frame detection instead
    msw->health_running = 0;
    // ret = pthread_create(&msw->health_thread, NULL, mswitch_health_monitor, msw);
    // if (ret != 0) {
    //     mswitch_log(msw, AV_LOG_ERROR, "Failed to create health monitoring thread\n");
    //     return AVERROR(ret);
    // }
    mswitch_log(msw, AV_LOG_INFO, "Health monitoring thread disabled - using immediate duplicate frame detection\n");
    
    // Start webhook server if enabled
    if (msw->webhook.enable) {
        ret = mswitch_webhook_start(msw);
        if (ret < 0) {
            mswitch_log(msw, AV_LOG_ERROR, "Failed to start webhook server\n");
            return ret;
        }
    }
    
    // Start CLI interface if enabled
    if (msw->cli.enable) {
        ret = mswitch_cli_start(msw);
        if (ret < 0) {
            mswitch_log(msw, AV_LOG_ERROR, "Failed to start CLI interface\n");
            return ret;
        }
    }
    
    mswitch_log(msw, AV_LOG_INFO, "MSwitch controller started successfully\n");
    return 0;
}

int mswitch_stop(MSwitchContext *msw)
{
    int i;
    
    mswitch_log(msw, AV_LOG_INFO, "Stopping MSwitch controller\n");
    
    // Stop health monitoring
    if (msw->health_running) {
        msw->health_running = 0;
        pthread_join(msw->health_thread, NULL);
    }
    
    // Stop webhook server
    if (msw->webhook.server_running) {
        mswitch_webhook_stop(msw);
    }
    
    // Stop CLI interface
    if (msw->cli.cli_running) {
        mswitch_cli_stop(msw);
    }
    
    // Stop all source threads
    for (i = 0; i < msw->nb_sources; i++) {
        MSwitchSource *src = &msw->sources[i];
        if (src->thread_running) {
            src->thread_running = 0;
            pthread_cond_signal(&src->cond);
            pthread_join(src->demux_thread, NULL);
            pthread_join(src->decode_thread, NULL);
        }
    }
    
    mswitch_log(msw, AV_LOG_INFO, "MSwitch controller stopped\n");
    return 0;
}

int mswitch_switch_to(MSwitchContext *msw, const char *source_id)
{
    int target_index = -1;
    int i;
    
    if (!msw || !source_id) {
        return AVERROR(EINVAL);
    }
    
    // Check if source_id is a numeric index (e.g., "0", "1", "2")
    if (source_id[0] >= '0' && source_id[0] <= '9' && source_id[1] == '\0') {
        // Numeric index
        target_index = source_id[0] - '0';
        if (target_index < 0 || target_index >= msw->nb_sources) {
            mswitch_log(msw, AV_LOG_ERROR, "Source index %d out of range (0-%d)\n", 
                       target_index, msw->nb_sources - 1);
            return AVERROR(EINVAL);
        }
        mswitch_log(msw, AV_LOG_INFO, "Parsed numeric index: %d\n", target_index);
    } else {
        // Find target source by ID (e.g., "s0", "s1", "s2")
        for (i = 0; i < msw->nb_sources; i++) {
            if (strcmp(msw->sources[i].id, source_id) == 0) {
                target_index = i;
                break;
            }
        }
        
        if (target_index == -1) {
            mswitch_log(msw, AV_LOG_ERROR, "Source '%s' not found\n", source_id);
            return AVERROR(EINVAL);
        }
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Switch request: target=%d (%s), current=%d\n", 
                target_index, source_id, msw->active_source_index);
    
    if (target_index == msw->active_source_index) {
        mswitch_log(msw, AV_LOG_INFO, "Source '%s' is already active\n", source_id);
        return 0;
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Switching from source %d to source %d (%s)\n", 
                msw->active_source_index, target_index, source_id);
    
    // Perform switch based on mode
    switch (msw->mode) {
        case MSW_MODE_SEAMLESS:
            return mswitch_switch_seamless(msw, target_index);
        case MSW_MODE_GRACEFUL:
            return mswitch_switch_graceful(msw, target_index);
        case MSW_MODE_CUTOVER:
            return mswitch_switch_cutover(msw, target_index);
        default:
            mswitch_log(msw, AV_LOG_ERROR, "Unknown switch mode\n");
            return AVERROR(EINVAL);
    }
}

// Filter-based switching implementation
static int mswitch_update_filter_map(MSwitchContext *msw, int target_index)
{
    if (!msw) {
        av_log(NULL, AV_LOG_ERROR, "[MSwitch] mswitch_update_filter_map: msw is NULL\n");
        return AVERROR(EINVAL);
    }
    
    AVFilterContext *streamselect = (AVFilterContext *)msw->streamselect_ctx;
    
    av_log(NULL, AV_LOG_WARNING, "[MSwitch] >>> mswitch_update_filter_map called: target_index=%d, streamselect=%p\n", 
           target_index, (void*)streamselect);
    
    if (!streamselect) {
        av_log(NULL, AV_LOG_WARNING, "[MSwitch] streamselect filter not initialized yet, logical switch only (will update filter when available)\n");
        return 0;  // Not an error - just means filter hasn't been created yet
    }
    
    // Check if filter has the option
    av_log(NULL, AV_LOG_WARNING, "[MSwitch] streamselect filter name: %s\n", 
           streamselect->filter ? streamselect->filter->name : "NULL");
    
    // Update the streamselect filter's "map" parameter
    char map_str[16];
    snprintf(map_str, sizeof(map_str), "%d", target_index);
    
    av_log(NULL, AV_LOG_WARNING, "[MSwitch] Calling avfilter_process_command with map_str='%s'\n", map_str);
    
    // Use avfilter_process_command instead of av_opt_set for runtime parameter changes
    char response[256] = {0};
    int ret = avfilter_process_command(streamselect, "map", map_str, response, sizeof(response), 0);
    
    av_log(NULL, AV_LOG_WARNING, "[MSwitch] avfilter_process_command returned: %d (%s), response='%s'\n", 
           ret, ret < 0 ? av_err2str(ret) : "success", response);
    
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "[MSwitch] Failed to update streamselect map to %d: %s\n", 
               target_index, av_err2str(ret));
        return ret;
    }
    
    av_log(NULL, AV_LOG_WARNING, "[MSwitch] ✓ avfilter_process_command succeeded for map=%d\n", target_index);
    
    // Note: We can't easily verify the internal map[] array from here,
    // but if process_command returned 0, it should have updated it.
    // The streamselect filter will log the parse_mapping result.
    
    return 0;
}

int mswitch_switch_seamless(MSwitchContext *msw, int target_index)
{
    if (!msw) {
        return AVERROR(EINVAL);
    }
    
    // Seamless switching via filter
    mswitch_log(msw, AV_LOG_INFO, "Performing seamless switch to source %d\n", target_index);
    
    pthread_mutex_lock(&msw->state_mutex);
    msw->switching = 1;
    
    // Update filter first, then update state
    int ret = mswitch_update_filter_map(msw, target_index);
    
    msw->active_source_index = target_index;
    msw->last_switch_time = av_gettime();
    msw->switching = 0;
    pthread_cond_broadcast(&msw->switch_cond);
    pthread_mutex_unlock(&msw->state_mutex);
    
    return ret;
}

int mswitch_switch_graceful(MSwitchContext *msw, int target_index)
{
    if (!msw) {
        return AVERROR(EINVAL);
    }
    
    // Graceful switching via filter
    mswitch_log(msw, AV_LOG_INFO, "Performing graceful switch to source %d\n", target_index);
    
    pthread_mutex_lock(&msw->state_mutex);
    msw->switching = 1;
    
    // Update filter first, then update state
    int ret = mswitch_update_filter_map(msw, target_index);
    
    msw->active_source_index = target_index;
    msw->last_switch_time = av_gettime();
    msw->switching = 0;
    pthread_cond_broadcast(&msw->switch_cond);
    pthread_mutex_unlock(&msw->state_mutex);
    
    return ret;
}

int mswitch_switch_cutover(MSwitchContext *msw, int target_index)
{
    if (!msw) {
        return AVERROR(EINVAL);
    }
    
    // Cutover switching via filter
    mswitch_log(msw, AV_LOG_INFO, "Performing cutover switch to source %d\n", target_index);
    
    pthread_mutex_lock(&msw->state_mutex);
    msw->switching = 1;
    
    // Update filter first, then update state
    int ret = mswitch_update_filter_map(msw, target_index);
    
    msw->active_source_index = target_index;
    msw->last_switch_time = av_gettime();
    msw->switching = 0;
    pthread_cond_broadcast(&msw->switch_cond);
    pthread_mutex_unlock(&msw->state_mutex);
    
    return ret;
}

// Filter-based switching setup
int mswitch_setup_filter(MSwitchContext *msw, void *filter_graph, void *streamselect_ctx)
{
    if (!msw || !filter_graph || !streamselect_ctx) {
        return AVERROR(EINVAL);
    }
    
    msw->filter_graph = filter_graph;
    msw->streamselect_ctx = streamselect_ctx;
    
    mswitch_log(msw, AV_LOG_INFO, "Filter-based switching initialized (streamselect filter attached)\n");
    
    // Note: The mswitch filter will start with map=0 by default (from the filter_complex)
    // We don't need to set the initial map here as it's already configured in the filter graph
    mswitch_log(msw, AV_LOG_INFO, "Filter setup complete - will use runtime switching via avfilter_process_command\n");
    
    return 0;
}

int mswitch_detect_black_frame(AVFrame *frame)
{
    int x, y;
    int64_t sum = 0;
    int64_t sum_sq = 0;
    int pixel_count = 0;
    
    if (!frame || frame->format != AV_PIX_FMT_YUV420P) {
        return 0; // Not a YUV420P frame, can't detect black
    }
    
    // Check Y plane only
    uint8_t *data = frame->data[0];
    int linesize = frame->linesize[0];
    int width = frame->width;
    int height = frame->height;
    
    for (y = 0; y < height; y++) {
        for (x = 0; x < width; x++) {
            int pixel = data[y * linesize + x];
            sum += pixel;
            sum_sq += pixel * pixel;
            pixel_count++;
        }
    }
    
    if (pixel_count == 0) {
        return 0;
    }
    
    int64_t mean = sum / pixel_count;
    int64_t variance = (sum_sq / pixel_count) - (mean * mean);
    
    return (mean < MSW_BLACK_Y_MEAN_THRESHOLD && variance < MSW_BLACK_VARIANCE_THRESHOLD);
}

// Update frame timestamp for a source (called when frame is received)
void mswitch_update_frame_timestamp(MSwitchContext *msw, int source_index)
{
    if (source_index >= 0 && source_index < msw->nb_sources) {
        MSwitchSource *source = &msw->sources[source_index];
        pthread_mutex_lock(&source->mutex);
        source->last_packet_time = av_gettime() / 1000; // Convert to ms
        pthread_mutex_unlock(&source->mutex);
    }
}


int mswitch_detect_stream_loss(MSwitchSource *source, int64_t current_time)
{
    // New approach: Detect stream loss by monitoring duplicate frames
    // When a source drops, FFmpeg will start sending duplicate frames
    // We can detect this by checking if we've had more than 500ms of duplicate frames
    
    // For now, implement a simple approach:
    // - If the source is not healthy, check how long it's been unhealthy
    // - If it's been unhealthy for more than 500ms, consider it stream loss
    if (!source->is_healthy) {
        int64_t time_since_unhealthy = current_time - source->last_health_check;
        if (time_since_unhealthy > 500) { // 500ms of being unhealthy
            mswitch_log(NULL, AV_LOG_WARNING, "[DEBUG] Stream loss detected: source unhealthy for %lld ms\n", 
                       time_since_unhealthy);
            return 1;
        }
    }
    
    return 0;
}

int mswitch_detect_pid_loss(MSwitchSource *source)
{
    // PID loss detection is specific to MPEG-TS
    // For now, return 0 (no PID loss detected)
    return 0;
}

int mswitch_detect_cc_errors(MSwitchSource *source)
{
    // CC error detection is specific to MPEG-TS
    // For now, return 0 (no CC errors detected)
    return 0;
}

int mswitch_detect_cc_errors_per_sec(MSwitchSource *source, int64_t current_time)
{
    // Calculate CC errors per second
    if (source->last_health_check == 0) {
        source->last_health_check = current_time;
        return 0;
    }
    
    int64_t time_diff = current_time - source->last_health_check;
    if (time_diff >= 1000) { // 1 second
        source->cc_errors_per_sec = source->cc_error_count;
        source->cc_error_count = 0;
        source->last_health_check = current_time;
    }
    
    return source->cc_errors_per_sec;
}

int mswitch_detect_packet_loss_percent(MSwitchSource *source, int64_t current_time)
{
    // Initialize window if needed
    if (source->packet_loss_window_start == 0) {
        source->packet_loss_window_start = current_time;
        return 0;
    }
    
    int64_t window_duration = current_time - source->packet_loss_window_start;
    int64_t window_duration_sec = window_duration / 1000;
    
    // Check if we need to update the window
    if (window_duration_sec >= source->buffer_size) { // Use buffer_size as window size for now
        // Calculate packet loss percentage for this window
        if (source->packets_in_window > 0) {
            source->current_packet_loss_percent = 
                (float)(source->lost_packets_in_window * 100.0f) / source->packets_in_window;
        } else {
            source->current_packet_loss_percent = 0.0f;
        }
        
        // Reset window
        source->packet_loss_window_start = current_time;
        source->packets_in_window = 0;
        source->lost_packets_in_window = 0;
    }
    
    return (source->current_packet_loss_percent > 0.0f) ? 1 : 0;
}

int mswitch_auto_failover_check(MSwitchContext *msw)
{
    if (!msw->auto_failover.enable) {
        return 0;
    }
    
    // Check if current source is unhealthy
    int current_source = msw->active_source_index;
    if (current_source < 0 || current_source >= msw->nb_sources) {
        return 0;
    }
    
    MSwitchSource *current = &msw->sources[current_source];
    if (current->is_healthy) {
        return 0; // Current source is healthy, no need to failover
    }
    
    mswitch_log(msw, AV_LOG_WARNING, "Current source %d (%s) is unhealthy, checking for failover...\n", 
               current_source, current->id);
    
    // Find the best alternative source
    int best_source = -1;
    int best_priority = -1;
    
    for (int i = 0; i < msw->nb_sources; i++) {
        if (i == current_source) continue; // Skip current source
        
        MSwitchSource *source = &msw->sources[i];
        
        // For inactive sources, assume they're healthy unless proven otherwise
        // Only the active source is monitored for health issues
        if (i != current_source) {
            // Inactive sources are considered healthy for failover
            source->is_healthy = 1;
        }
        
        // Check if source is healthy
        if (!source->is_healthy) {
            mswitch_log(msw, AV_LOG_DEBUG, "Source %d (%s) is unhealthy, skipping\n", i, source->id);
            continue;
        }
        
        // Calculate priority (lower is better)
        int priority = i; // Simple priority: prefer lower index
        
        if (best_source == -1 || priority < best_priority) {
            best_source = i;
            best_priority = priority;
        }
    }
    
    if (best_source == -1) {
        mswitch_log(msw, AV_LOG_ERROR, "No healthy sources available for failover\n");
        return AVERROR(EAGAIN);
    }
    
    // Perform failover
    mswitch_log(msw, AV_LOG_WARNING, "Auto-failover: switching from source %d (%s) to source %d (%s)\n",
               current_source, current->id, best_source, msw->sources[best_source].id);
    
    // Enqueue failover command
    int ret = mswitch_cmd_queue_enqueue(msw, msw->sources[best_source].id);
    if (ret < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to enqueue failover command: %s\n", av_err2str(ret));
        return ret;
    }
    
    // Update failover statistics
    msw->auto_failover.failover_count++;
    msw->auto_failover.last_failover_time = av_gettime() / 1000;
    
    return 0;
}

// Function to check for duplicate frame threshold and trigger immediate failover
void mswitch_check_duplicate_threshold(MSwitchContext *msw)
{
    if (!msw->auto_failover.enable) {
        return;
    }
    
    int active_source = msw->active_source_index;
    if (active_source < 0 || active_source >= msw->nb_sources) {
        return;
    }
    
    MSwitchSource *source = &msw->sources[active_source];
    int64_t current_time = av_gettime() / 1000;
    
    // Wait for output to start and stabilize before beginning health monitoring
    // This ensures all streams are fully ingested, processed, and stabilized
    static int monitoring_started = 0;
    static int64_t first_frame_time = 0;
    
    // Check if we've received our first frame (indicates output has started)
    if (!monitoring_started) {
        // Look for any source that has been updated recently (within last 3 seconds)
        // This indicates the output pipeline is working
        int output_started = 0;
        for (int i = 0; i < msw->nb_sources; i++) {
            MSwitchSource *src = &msw->sources[i];
            int64_t time_since_update = current_time - src->last_packet_time;
            if (time_since_update < 3000) { // Source updated within last 3 seconds
                output_started = 1;
                break;
            }
        }
        
        // Log buffer tracking during startup
        if (current_time % 2000 < 100) { // Log every 2 seconds
            mswitch_log(msw, AV_LOG_INFO, "[BUFFER_TRACK] Startup monitoring - output_started=%d, time=%ldms\n",
                       output_started, current_time);
        }
        
        if (output_started) {
            if (first_frame_time == 0) {
                first_frame_time = current_time;
                mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Output started, beginning stabilization period\n");
            }
            
            // Wait 30 seconds after first frame to ensure complete stabilization
            // This allows FFmpeg to fully initialize and stabilize all streams
            if (current_time - first_frame_time < 30000) { // 30 second stabilization period
                mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Stabilizing output... (%"PRId64"ms remaining) - NO HEALTH MONITORING\n", 
                           30000 - (current_time - first_frame_time));
                return; // CRITICAL: Exit early to prevent health monitoring during grace period
            }
            
            monitoring_started = 1;
            mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Output stabilized, health monitoring now active\n");
        } else {
            mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Waiting for output to start before monitoring...\n");
            return;
        }
    }
    
    // Note: Active source index should be updated when switches occur
    // For now, we'll rely on the switch functions to update this correctly
    
    // CRITICAL: Health monitoring should only run after the grace period
    mswitch_log(msw, AV_LOG_INFO, "[DEBUG] HEALTH MONITORING ACTIVE - checking source health\n");
    
    // Implement reliable input health detection using multiple FFmpeg metrics
    // This approach monitors dropped frames, frame rate, and input stream health
    
    // Get current metrics from FFmpeg's output stream
    extern uint64_t global_dup_count;
    extern uint64_t global_drop_count;
    extern uint64_t global_packets_written;
    
    uint64_t current_dup_count = global_dup_count;
    uint64_t current_drop_count = global_drop_count;
    uint64_t current_packets_written = global_packets_written;
    
    // Track metrics over time to detect trends
    static uint64_t last_dup_count = 0;
    static uint64_t last_drop_count = 0;
    static uint64_t last_packets_written = 0;
    static int64_t last_health_check = 0;
    
    if (last_health_check > 0) {
        int64_t time_diff = current_time - last_health_check;
        
        if (time_diff > 0) {
            // Calculate rates
            double dup_rate = (double)(current_dup_count - last_dup_count) / (time_diff / 1000.0);
            double drop_rate = (double)(current_drop_count - last_drop_count) / (time_diff / 1000.0);
            double frame_rate = (double)(current_packets_written - last_packets_written) / (time_diff / 1000.0);
            
            mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Input health check: active_source=%d, dup_rate=%.2f/s, drop_rate=%.2f/s, frame_rate=%.2f/s, is_healthy=%d\n", 
                       active_source, dup_rate, drop_rate, frame_rate, source->is_healthy);
            
            // Debug: Show raw counts to understand why drop_rate is 0
            mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Raw counts: dup=%"PRIu64", drop=%"PRIu64", packets=%"PRIu64", time_diff=%"PRId64"ms\n", 
                       current_dup_count, current_drop_count, current_packets_written, time_diff);
            
            // Check for input loss indicators with more sensitive thresholds:
            // 1. High drop rate (>1 drops per second) - indicates input issues
            // 2. Low frame rate (<5 frames per second) - indicates input problems
            // 3. High duplicate rate (>10 duplicates per second) - indicates source issues
            
            int input_loss_detected = 0;
            const char *loss_reason = "";
            
            if (drop_rate > 1.0) {
                input_loss_detected = 1;
                loss_reason = "high drop rate";
            } else if (frame_rate < 5.0) {
                input_loss_detected = 1;
                loss_reason = "low frame rate";
            } else if (dup_rate > 10.0) {
                input_loss_detected = 1;
                loss_reason = "high duplicate rate";
            }
            
            if (input_loss_detected) {
                if (source->is_healthy) {
                    source->is_healthy = 0;
                    source->last_health_check = current_time;
                    mswitch_log(msw, AV_LOG_WARNING, "Source %d (%s) marked as unhealthy - %s: dup=%.2f/s, drop=%.2f/s, fps=%.2f/s\n", 
                               active_source, source->id, loss_reason, dup_rate, drop_rate, frame_rate);
                    
                    // For critical failures (very low frame rate), trigger immediate failover
                    if (frame_rate < 1.0) {
                        mswitch_log(msw, AV_LOG_WARNING, "Critical input loss detected (frame_rate=%.2f/s), triggering immediate failover\n", frame_rate);
                        mswitch_auto_failover_check(msw);
                    }
                } else {
                    // Check if it's been unhealthy for more than 200ms (faster response)
                    int64_t time_since_unhealthy = current_time - source->last_health_check;
                    if (time_since_unhealthy > 200) { // 200ms threshold
                        mswitch_log(msw, AV_LOG_WARNING, "Input loss threshold exceeded (200ms), triggering failover\n");
                        mswitch_auto_failover_check(msw);
                    }
                }
            } else {
                // Input is healthy, mark as healthy
                if (!source->is_healthy) {
                    source->is_healthy = 1;
                    source->last_recovery_time = current_time;
                    mswitch_log(msw, AV_LOG_INFO, "Source %d (%s) recovered - input healthy: dup=%.2f/s, drop=%.2f/s, fps=%.2f/s\n", 
                               active_source, source->id, dup_rate, drop_rate, frame_rate);
                }
            }
        }
    }
    
    // Update tracking variables
    last_dup_count = current_dup_count;
    last_drop_count = current_drop_count;
    last_packets_written = current_packets_written;
    last_health_check = current_time;
}

int mswitch_check_health(MSwitchContext *msw, int source_index)
{
    if (source_index < 0 || source_index >= msw->nb_sources) {
        return AVERROR(EINVAL);
    }
    
    MSwitchSource *source = &msw->sources[source_index];
    int64_t current_time = av_gettime() / 1000; // Convert to ms
    
    // For the active source, check if it's sending duplicate frames
    if (source_index == msw->active_source_index) {
        // Check if this source has been active for a while and might be sending duplicates
        int64_t time_since_last_update = current_time - source->last_packet_time;
        if (time_since_last_update > 2000) { // 2 seconds without updates
            if (source->is_healthy) {
                source->is_healthy = 0;
                source->last_health_check = current_time;
                mswitch_log(msw, AV_LOG_WARNING, "Source %d (%s) marked as unhealthy - possible duplicate frames\n", 
                           source_index, source->id);
            }
        }
        // Don't automatically mark as healthy - let it stay unhealthy until real recovery
        // This allows the duplicate frame threshold detection to work
    } else {
        // For inactive sources, keep them healthy since they're not being used
        if (!source->is_healthy) {
            source->is_healthy = 1;
            source->last_recovery_time = current_time;
        }
    }
    
    // Check stream loss using the new duplicate frame detection
    if (mswitch_detect_stream_loss(source, current_time)) {
        source->stream_loss_count++;
        mswitch_log(msw, AV_LOG_WARNING, "Stream loss confirmed for source %d (%s)\n", 
                   source_index, source->id);
        return 1;
    }
    
    // Check PID loss (MPEG-TS only)
    if (mswitch_detect_pid_loss(source)) {
        source->pid_loss_count++;
        source->is_healthy = 0;
        mswitch_log(msw, AV_LOG_WARNING, "PID loss detected for source %d\n", source_index);
        return 1;
    }
    
    // Check CC errors per second (MPEG-TS only)
    int cc_errors_per_sec = mswitch_detect_cc_errors_per_sec(source, current_time);
    if (cc_errors_per_sec > msw->auto_failover.thresholds.cc_errors_per_sec) {
        source->is_healthy = 0;
        mswitch_log(msw, AV_LOG_WARNING, "CC errors per second (%d) exceeded threshold (%d) for source %d\n", 
                   cc_errors_per_sec, msw->auto_failover.thresholds.cc_errors_per_sec, source_index);
        return 1;
    }
    
    // Check packet loss percentage
    if (mswitch_detect_packet_loss_percent(source, current_time)) {
        if (source->current_packet_loss_percent > msw->auto_failover.thresholds.packet_loss_percent) {
            source->is_healthy = 0;
            mswitch_log(msw, AV_LOG_WARNING, "Packet loss percentage (%.2f%%) exceeded threshold (%.2f%%) for source %d\n", 
                       source->current_packet_loss_percent, msw->auto_failover.thresholds.packet_loss_percent, source_index);
            return 1;
        }
    }
    
    source->is_healthy = 1;
    return 0;
}

// HTTP server thread for webhook
static void *mswitch_webhook_server_thread(void *arg)
{
    MSwitchContext *msw = (MSwitchContext *)arg;
    int server_fd, client_fd;
    struct sockaddr_in address;
    int opt = 1;
    int addrlen = sizeof(address);
    char buffer[1024] = {0};
    char response[1024] = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n{\"status\":\"ok\"}";
    
    mswitch_log(msw, AV_LOG_INFO, "Starting webhook server thread on port %d\n", msw->webhook.port);
    
    // Create socket
    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Webhook socket creation failed\n");
        return NULL;
    }
    
    // Set socket options
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt))) {
        mswitch_log(msw, AV_LOG_ERROR, "Webhook setsockopt failed\n");
        close(server_fd);
        return NULL;
    }
    
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(msw->webhook.port);
    
    // Bind socket
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Webhook bind failed on port %d\n", msw->webhook.port);
        close(server_fd);
        return NULL;
    }
    
    // Listen for connections
    if (listen(server_fd, 3) < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Webhook listen failed\n");
        close(server_fd);
        return NULL;
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Webhook server listening on port %d\n", msw->webhook.port);
    msw->webhook.server_running = 1;
    
    // Accept connections while server is running
    while (msw->webhook.server_running) {
        // Set socket to non-blocking for periodic checks
        fd_set readfds;
        struct timeval timeout;
        
        FD_ZERO(&readfds);
        FD_SET(server_fd, &readfds);
        timeout.tv_sec = 1;
        timeout.tv_usec = 0;
        
        int activity = select(server_fd + 1, &readfds, NULL, NULL, &timeout);
        
        if (activity < 0) {
            if (!msw->webhook.server_running) break;
            mswitch_log(msw, AV_LOG_WARNING, "Webhook select error: %s\n", strerror(errno));
            continue;
        }
        
        if (activity == 0) {
            // Timeout, check if we should continue
            continue;
        }
        
        if (FD_ISSET(server_fd, &readfds)) {
            if ((client_fd = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen)) < 0) {
                if (!msw->webhook.server_running) break;
                mswitch_log(msw, AV_LOG_WARNING, "Webhook accept error: %s\n", strerror(errno));
                continue;
            }
            
            // Read request
            int bytes_read = read(client_fd, buffer, 1023);
            
            mswitch_log(msw, AV_LOG_WARNING, "[Webhook] Received request, bytes_read=%d\n", bytes_read);
            
            if (bytes_read > 0) {
                buffer[bytes_read] = '\0';
                
                // Log the raw request for debugging
                mswitch_log(msw, AV_LOG_WARNING, "[Webhook] Raw request:\n%s\n", buffer);
                
                // Parse request for switch command
                // Expected formats:
                //   1. POST /switch/1 (URL path)
                //   2. POST /switch with JSON body {"source":"s1"}
                if (strstr(buffer, "POST /switch")) {
                    mswitch_log(msw, AV_LOG_WARNING, "[Webhook] POST /switch detected\n");
                    
                    char source_id[16] = {0};
                    int source_found = 0;
                    
                    // First, try to parse source ID from URL path (e.g., /switch/1)
                    char *url_start = strstr(buffer, "POST /switch/");
                    if (url_start) {
                        url_start += strlen("POST /switch/");
                        mswitch_log(msw, AV_LOG_WARNING, "[Webhook] Parsing source ID from URL path\n");
                        
                        // Extract source ID from URL (could be "0", "1", "2", "s0", "s1", etc.)
                        int j = 0;
                        while (j < 15 && *url_start && *url_start != ' ' && *url_start != '\r' && *url_start != '\n') {
                            source_id[j++] = *url_start++;
                        }
                        source_id[j] = '\0';
                        
                        if (source_id[0] != '\0') {
                            source_found = 1;
                            mswitch_log(msw, AV_LOG_WARNING, "[Webhook] Extracted source ID from URL: '%s'\n", source_id);
                        }
                    }
                    
                    // If not found in URL, try JSON body
                    if (!source_found) {
                        char *body = strstr(buffer, "\r\n\r\n");
                        if (body) {
                            body += 4; // Skip the \r\n\r\n
                            mswitch_log(msw, AV_LOG_WARNING, "[Webhook] Body: %s\n", body);
                            
                            // Simple JSON parsing - look for "source":"sX"
                            char *source_start = strstr(body, "\"source\"");
                            if (source_start) {
                                mswitch_log(msw, AV_LOG_WARNING, "[Webhook] Found 'source' field in JSON\n");
                                
                                source_start = strchr(source_start, ':');
                                if (source_start) {
                                    source_start++; // Skip ':'
                                    while (*source_start == ' ' || *source_start == '"') source_start++;
                                    
                                    // Extract source ID (s0, s1, s2, etc.)
                                    int j = 0;
                                    while (j < 15 && *source_start && *source_start != '"' && *source_start != '}') {
                                        source_id[j++] = *source_start++;
                                    }
                                    source_id[j] = '\0';
                                    source_found = 1;
                                }
                            }
                        }
                    }
                    
                    // Process the switch command if source was found
                    if (source_found) {
                        // Enqueue the switch command (thread-safe)
                        mswitch_log(msw, AV_LOG_WARNING, "[Webhook] *** ENQUEUING SWITCH TO SOURCE: %s ***\n", source_id);
                        
                        int ret = mswitch_cmd_queue_enqueue(msw, source_id);
                        
                        if (ret == 0) {
                            snprintf(response, sizeof(response),
                                    "HTTP/1.1 200 OK\r\n"
                                    "Content-Type: application/json\r\n\r\n"
                                    "{\"status\":\"ok\",\"source\":\"%s\"}", source_id);
                        } else {
                            snprintf(response, sizeof(response),
                                    "HTTP/1.1 400 Bad Request\r\n"
                                    "Content-Type: application/json\r\n\r\n"
                                    "{\"status\":\"error\",\"message\":\"Switch failed\",\"code\":%d}", ret);
                        }
                    } else {
                        mswitch_log(msw, AV_LOG_ERROR, "[Webhook] Source ID not found in URL or body\n");
                        snprintf(response, sizeof(response),
                                "HTTP/1.1 400 Bad Request\r\n"
                                "Content-Type: application/json\r\n\r\n"
                                "{\"status\":\"error\",\"message\":\"Source ID not found\"}");
                    }
                } else {
                    mswitch_log(msw, AV_LOG_WARNING, "[Webhook] Not a POST /switch request\n");
                }
            } else {
                mswitch_log(msw, AV_LOG_ERROR, "[Webhook] Failed to read request: bytes_read=%d\n", bytes_read);
            }
            
            // Send response
            send(client_fd, response, strlen(response), 0);
            
            close(client_fd);
        }
    }
    
    close(server_fd);
    mswitch_log(msw, AV_LOG_INFO, "Webhook server thread stopped\n");
    return NULL;
}

// Webhook server implementations
int mswitch_webhook_start(MSwitchContext *msw)
{
    int ret;
    
    if (!msw->webhook.enable) {
        mswitch_log(msw, AV_LOG_INFO, "Webhook disabled - use interactive commands (0/1/2) instead\n");
        return 0;
    }
    
    if (msw->webhook.server_running) {
        return 0; // Already running
    }
    
    // Start webhook server thread
    ret = pthread_create(&msw->webhook.server_thread, NULL, mswitch_webhook_server_thread, msw);
    if (ret != 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to create webhook server thread: %d\n", ret);
        return AVERROR(ret);
    }
    
    pthread_detach(msw->webhook.server_thread);
    
    // Give the server time to start
    usleep(100000); // 100ms
    
    mswitch_log(msw, AV_LOG_INFO, "Webhook server started on port %d\n", msw->webhook.port);
    return 0;
}

int mswitch_webhook_stop(MSwitchContext *msw)
{
    if (!msw->webhook.server_running) {
        return 0; // Already stopped
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Stopping webhook server\n");
    msw->webhook.server_running = 0;
    
    // Note: Thread is detached, so no need to join
    mswitch_log(msw, AV_LOG_INFO, "Webhook server stopped\n");
    return 0;
}

int mswitch_webhook_handle_request(MSwitchContext *msw, const char *json_request, char **json_response)
{
    // Placeholder for webhook request handling
    *json_response = av_strdup("{\"status\":\"ok\"}");
    return 0;
}

// CLI thread function - reads commands from a file instead of stdin
static void *mswitch_cli_thread(void *arg)
{
    MSwitchContext *msw = (MSwitchContext *)arg;
    char command_file[] = "/tmp/mswitch_cmd";
    char input[256];
    FILE *fp;
    
    mswitch_log(msw, AV_LOG_INFO, "CLI interface ready. Send commands by writing to %s\n", command_file);
    mswitch_log(msw, AV_LOG_INFO, "Commands: echo '0' > %s  (switch to source 0)\n", command_file);
    mswitch_log(msw, AV_LOG_INFO, "Commands: echo '1' > %s  (switch to source 1)\n", command_file);
    mswitch_log(msw, AV_LOG_INFO, "Commands: echo '2' > %s  (switch to source 2)\n", command_file);
    mswitch_log(msw, AV_LOG_INFO, "Commands: echo 's' > %s  (show status)\n", command_file);
    
    // Create/clear the command file
    fp = fopen(command_file, "w");
    if (fp) {
        fclose(fp);
    }
    
    while (msw->cli.cli_running) {
        fp = fopen(command_file, "r");
        if (fp) {
            if (fgets(input, sizeof(input), fp) != NULL) {
                // Remove newline and whitespace
                input[strcspn(input, "\n\r \t")] = 0;
                
                if (strlen(input) == 1) {
                    char cmd = input[0];
                    
                    if (cmd >= '0' && cmd <= '2') {
                        int source_index = cmd - '0';
                        if (source_index < msw->nb_sources) {
                            msw->active_source_index = source_index;
                            mswitch_log(msw, AV_LOG_INFO, "Switched to source %d (%s)\n", 
                                       source_index, msw->sources[source_index].id);
                        } else {
                            mswitch_log(msw, AV_LOG_WARNING, "Source %d not available (only %d sources)\n", 
                                       source_index, msw->nb_sources);
                        }
                    } else if (cmd == 's') {
                        mswitch_log(msw, AV_LOG_INFO, "Status: Active source = %d (%s), Total sources = %d\n",
                                   msw->active_source_index, 
                                   msw->sources[msw->active_source_index].id,
                                   msw->nb_sources);
                    } else if (cmd != '\0') {
                        mswitch_log(msw, AV_LOG_INFO, "Unknown command '%c'. Use 0-2 or s\n", cmd);
                    }
                    
                    // Clear the command file after processing
                    fclose(fp);
                    fp = fopen(command_file, "w");
                    if (fp) {
                        fclose(fp);
                    }
                } else {
                    fclose(fp);
                }
            } else {
                fclose(fp);
            }
        }
        usleep(500000); // 500ms delay
    }
    
    // Clean up command file
    unlink(command_file);
    return NULL;
}

int mswitch_cli_start(MSwitchContext *msw)
{
    int ret;
    
    if (msw->cli.cli_running) {
        return 0; // Already running
    }
    
    msw->cli.cli_running = 1;
    
    // Start CLI thread
    ret = pthread_create(&msw->cli.cli_thread, NULL, mswitch_cli_thread, msw);
    if (ret != 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to create CLI thread: %d\n", ret);
        msw->cli.cli_running = 0;
        return AVERROR(ret);
    }
    
    mswitch_log(msw, AV_LOG_INFO, "CLI interface started\n");
    return 0;
}

int mswitch_cli_stop(MSwitchContext *msw)
{
    if (!msw->cli.cli_running) {
        return 0; // Already stopped
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Stopping CLI interface\n");
    msw->cli.cli_running = 0;
    
    // Wait for CLI thread to finish
    pthread_join(msw->cli.cli_thread, NULL);
    
    mswitch_log(msw, AV_LOG_INFO, "CLI interface stopped\n");
    return 0;
}

// Command queue implementation (thread-safe)
int mswitch_cmd_queue_init(MSwitchContext *msw)
{
    if (!msw) {
        return AVERROR(EINVAL);
    }
    
    msw->cmd_queue.head = 0;
    msw->cmd_queue.tail = 0;
    
    if (pthread_mutex_init(&msw->cmd_queue.lock, NULL) != 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to initialize command queue mutex\n");
        return AVERROR(ENOMEM);
    }
    
    if (pthread_cond_init(&msw->cmd_queue.cond, NULL) != 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to initialize command queue condition\n");
        pthread_mutex_destroy(&msw->cmd_queue.lock);
        return AVERROR(ENOMEM);
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Command queue initialized\n");
    return 0;
}

void mswitch_cmd_queue_cleanup(MSwitchContext *msw)
{
    if (!msw) {
        return;
    }
    
    pthread_mutex_destroy(&msw->cmd_queue.lock);
    pthread_cond_destroy(&msw->cmd_queue.cond);
    
    mswitch_log(msw, AV_LOG_INFO, "Command queue cleaned up\n");
}

int mswitch_cmd_queue_enqueue(MSwitchContext *msw, const char *source_id)
{
    if (!msw || !source_id) {
        return AVERROR(EINVAL);
    }
    
    pthread_mutex_lock(&msw->cmd_queue.lock);
    
    // Check if queue is full
    int next_tail = (msw->cmd_queue.tail + 1) % 100;
    if (next_tail == msw->cmd_queue.head) {
        mswitch_log(msw, AV_LOG_WARNING, "Command queue is full, dropping command\n");
        pthread_mutex_unlock(&msw->cmd_queue.lock);
        return AVERROR(ENOSPC);
    }
    
    // Add command to queue
    strncpy(msw->cmd_queue.queue[msw->cmd_queue.tail].source_id, source_id, 15);
    msw->cmd_queue.queue[msw->cmd_queue.tail].source_id[15] = '\0';
    msw->cmd_queue.queue[msw->cmd_queue.tail].timestamp = av_gettime();
    msw->cmd_queue.tail = next_tail;
    
    // Signal that a command is available
    pthread_cond_signal(&msw->cmd_queue.cond);
    
    pthread_mutex_unlock(&msw->cmd_queue.lock);
    
    mswitch_log(msw, AV_LOG_INFO, "Command enqueued: %s\n", source_id);
    return 0;
}

int mswitch_cmd_queue_process(MSwitchContext *msw)
{
    if (!msw) {
        return AVERROR(EINVAL);
    }
    
    pthread_mutex_lock(&msw->cmd_queue.lock);
    
    // Check if queue is empty
    if (msw->cmd_queue.head == msw->cmd_queue.tail) {
        pthread_mutex_unlock(&msw->cmd_queue.lock);
        return 0; // No commands to process
    }
    
    // Get command from queue
    MSwitchCommand cmd = msw->cmd_queue.queue[msw->cmd_queue.head];
    msw->cmd_queue.head = (msw->cmd_queue.head + 1) % 100;
    
    pthread_mutex_unlock(&msw->cmd_queue.lock);
    
    // Process the command in main thread (thread-safe)
    mswitch_log(msw, AV_LOG_WARNING, "[MSwitch] *** PROCESSING COMMAND: %s ***\n", cmd.source_id);
    
    int ret = mswitch_switch_to(msw, cmd.source_id);
    if (ret < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to process command %s: %s\n", 
                   cmd.source_id, av_err2str(ret));
    } else {
        mswitch_log(msw, AV_LOG_WARNING, "[MSwitch] *** SUCCESSFULLY PROCESSED COMMAND: %s ***\n", cmd.source_id);
    }
    
    return ret;
}

int mswitch_cli_handle_command(MSwitchContext *msw, const char *command)
{
    // Placeholder for CLI command handling
    mswitch_log(msw, AV_LOG_INFO, "CLI command: %s\n", command);
    return 0;
}

// Utility functions
const char *mswitch_mode_to_string(MSwitchMode mode)
{
    switch (mode) {
        case MSW_MODE_SEAMLESS: return "seamless";
        case MSW_MODE_GRACEFUL: return "graceful";
        case MSW_MODE_CUTOVER: return "cutover";
        default: return "unknown";
    }
}

const char *mswitch_ingest_to_string(MSwitchIngest ingest)
{
    switch (ingest) {
        case MSW_INGEST_STANDBY: return "standby";
        case MSW_INGEST_HOT: return "hot";
        default: return "unknown";
    }
}

MSwitchMode mswitch_string_to_mode(const char *str)
{
    if (strcmp(str, "seamless") == 0) return MSW_MODE_SEAMLESS;
    if (strcmp(str, "graceful") == 0) return MSW_MODE_GRACEFUL;
    if (strcmp(str, "cutover") == 0) return MSW_MODE_CUTOVER;
    return MSW_MODE_GRACEFUL; // Default
}

MSwitchIngest mswitch_string_to_ingest(const char *str)
{
    if (strcmp(str, "standby") == 0) return MSW_INGEST_STANDBY;
    if (strcmp(str, "hot") == 0) return MSW_INGEST_HOT;
    return MSW_INGEST_HOT; // Default
}

// Health monitoring thread function
void *mswitch_health_monitor(void *arg)
{
    MSwitchContext *msw = (MSwitchContext *)arg;
    int i;
    int64_t last_failover_check = 0;
    int64_t last_health_check = 0;
    int64_t last_debug_log = 0;
    
    mswitch_log(msw, AV_LOG_INFO, "Health monitoring thread started\n");
    
    while (msw->health_running) {
        int64_t current_time = av_gettime() / 1000; // Convert to ms
        
        // Debug logging every 10 seconds
        if ((current_time - last_debug_log) >= 10000) {
            mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Health monitoring running, current_time=%lld\n", current_time);
            last_debug_log = current_time;
        }
        
        // Only check health every 30 seconds to minimize performance impact
        if ((current_time - last_health_check) >= 30000) {
            mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Checking health for all sources\n");
            for (i = 0; i < msw->nb_sources; i++) {
                mswitch_check_health(msw, i);
            }
            last_health_check = current_time;
        }
        
        // Check for auto-failover if enabled (every 5 seconds)
        if (msw->auto_failover.enable) {
            mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Auto-failover enabled, checking...\n");
            if ((current_time - last_failover_check) >= 5000) {
                mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Checking auto-failover\n");
                mswitch_auto_failover_check(msw);
                last_failover_check = current_time;
            }
        } else {
            mswitch_log(msw, AV_LOG_INFO, "[DEBUG] Auto-failover disabled\n");
        }
        
        // Sleep for 5 seconds to reduce CPU usage
        usleep(5000000);
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Health monitoring thread stopped\n");
    return NULL;
}
