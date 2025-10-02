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

#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>

// External global context declared in ffmpeg_opt.c
extern MSwitchContext global_mswitch_ctx;
extern int global_mswitch_enabled;

// Default health thresholds
#define MSW_DEFAULT_STREAM_LOSS_MS 2000
#define MSW_DEFAULT_PID_LOSS_MS 500
#define MSW_DEFAULT_BLACK_MS 800
#define MSW_DEFAULT_CC_ERRORS_PER_SEC 5
#define MSW_DEFAULT_PACKET_LOSS_PERCENT 2.0f
#define MSW_DEFAULT_PACKET_LOSS_WINDOW_SEC 10

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

int mswitch_init(MSwitchContext *msw, OptionsContext *o)
{
    int ret = 0;
    
    // Initialize only the runtime fields, preserving the option fields that were set by command-line parsing
    msw->active_source_index = 0;
    msw->last_switch_time = 0;
    msw->switching = 0;
    msw->metrics_enable = 0;
    msw->json_metrics = 0;
    
    // Initialize the sources array
    memset(msw->sources, 0, sizeof(msw->sources));
    msw->nb_sources = 0;
    
    // Initialize mutexes and conditions
    pthread_mutex_init(&msw->state_mutex, NULL);
    pthread_cond_init(&msw->switch_cond, NULL);
    
    // Initialize threading fields
    msw->health_running = 0;
    memset(&msw->health_thread, 0, sizeof(msw->health_thread));
    
    // Initialize metrics fields
    msw->metrics_file = NULL;
    
    // Use actual sources from the global context
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
    
    if (global_mswitch_ctx.mode_str) {
        if (strcmp(global_mswitch_ctx.mode_str, "seamless") == 0) {
            msw->mode = MSW_MODE_SEAMLESS;
        } else if (strcmp(global_mswitch_ctx.mode_str, "cutover") == 0) {
            msw->mode = MSW_MODE_CUTOVER;
        } else {
            msw->mode = MSW_MODE_GRACEFUL; // default
        }
    } else {
        msw->mode = MSW_MODE_GRACEFUL;
    }
    
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
    msw->auto_failover.enable = 0; // Auto failover not implemented yet
    msw->auto_failover.health_window_ms = MSW_DEFAULT_HEALTH_WINDOW_MS;
    
    // Initialize revert policy
    msw->revert.policy = MSW_REVERT_AUTO;
    msw->revert.health_window_ms = MSW_DEFAULT_HEALTH_WINDOW_MS;
    
    mswitch_log(msw, AV_LOG_INFO, "MSwitch initialized with %d sources\n", msw->nb_sources);
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
    
    // Cleanup sources
    for (i = 0; i < msw->nb_sources; i++) {
        MSwitchSource *src = &msw->sources[i];
        
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
    
    // Start health monitoring thread
    msw->health_running = 1;
    ret = pthread_create(&msw->health_thread, NULL, mswitch_health_monitor, msw);
    if (ret != 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to create health monitoring thread\n");
        return AVERROR(ret);
    }
    
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
    
    // Find target source index
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

int mswitch_switch_seamless(MSwitchContext *msw, int target_index)
{
    // Seamless switching requires bit-exact sources
    // For now, implement basic packet-level switching
    mswitch_log(msw, AV_LOG_INFO, "Performing seamless switch to source %d\n", target_index);
    
    pthread_mutex_lock(&msw->state_mutex);
    msw->switching = 1;
    msw->active_source_index = target_index;
    msw->last_switch_time = av_gettime();
    msw->switching = 0;
    pthread_cond_broadcast(&msw->switch_cond);
    pthread_mutex_unlock(&msw->state_mutex);
    
    return 0;
}

int mswitch_switch_graceful(MSwitchContext *msw, int target_index)
{
    // Graceful switching waits for next IDR frame
    mswitch_log(msw, AV_LOG_INFO, "Performing graceful switch to source %d\n", target_index);
    
    pthread_mutex_lock(&msw->state_mutex);
    msw->switching = 1;
    msw->active_source_index = target_index;
    msw->last_switch_time = av_gettime();
    msw->switching = 0;
    pthread_cond_broadcast(&msw->switch_cond);
    pthread_mutex_unlock(&msw->state_mutex);
    
    return 0;
}

int mswitch_switch_cutover(MSwitchContext *msw, int target_index)
{
    // Cutover switching is immediate
    mswitch_log(msw, AV_LOG_INFO, "Performing cutover switch to source %d\n", target_index);
    
    pthread_mutex_lock(&msw->state_mutex);
    msw->switching = 1;
    msw->active_source_index = target_index;
    msw->last_switch_time = av_gettime();
    msw->switching = 0;
    pthread_cond_broadcast(&msw->switch_cond);
    pthread_mutex_unlock(&msw->state_mutex);
    
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

int mswitch_detect_stream_loss(MSwitchSource *source, int64_t current_time)
{
    if (source->last_packet_time == 0) {
        source->last_packet_time = current_time;
        return 0;
    }
    
    int64_t time_since_last_packet = current_time - source->last_packet_time;
    return (time_since_last_packet > source->buffer_size * 1000); // Convert to ms
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

int mswitch_check_health(MSwitchContext *msw, int source_index)
{
    if (source_index < 0 || source_index >= msw->nb_sources) {
        return AVERROR(EINVAL);
    }
    
    MSwitchSource *source = &msw->sources[source_index];
    int64_t current_time = av_gettime() / 1000; // Convert to ms
    
    // Check stream loss
    if (mswitch_detect_stream_loss(source, current_time)) {
        source->stream_loss_count++;
        source->is_healthy = 0;
        mswitch_log(msw, AV_LOG_WARNING, "Stream loss detected for source %d\n", source_index);
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
    const char *response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n{\"status\":\"ok\"}";
    
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
            continue;
        }
        
        if (activity == 0) {
            // Timeout, check if we should continue
            continue;
        }
        
        if (FD_ISSET(server_fd, &readfds)) {
            if ((client_fd = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen)) < 0) {
                if (!msw->webhook.server_running) break;
                continue;
            }
            
            // Read request
            read(client_fd, buffer, 1024);
            
            // Send simple response
            send(client_fd, response, strlen(response), 0);
            
            close(client_fd);
        }
    }
    
    close(server_fd);
    mswitch_log(msw, AV_LOG_INFO, "Webhook server thread stopped\n");
    return NULL;
}

// Placeholder implementations for webhook and CLI
int mswitch_webhook_start(MSwitchContext *msw)
{
    int ret;
    
    if (msw->webhook.server_running) {
        return 0; // Already running
    }
    
    // Start webhook server thread
    ret = pthread_create(&msw->webhook.server_thread, NULL, mswitch_webhook_server_thread, msw);
    if (ret != 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to create webhook server thread: %d\n", ret);
        return AVERROR(ret);
    }
    
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
    
    // Wait for server thread to finish
    pthread_join(msw->webhook.server_thread, NULL);
    
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
    
    mswitch_log(msw, AV_LOG_INFO, "Health monitoring thread started\n");
    
    while (msw->health_running) {
        for (i = 0; i < msw->nb_sources; i++) {
            mswitch_check_health(msw, i);
        }
        
        // Sleep for 1 second
        usleep(1000000);
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Health monitoring thread stopped\n");
    return NULL;
}
