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
#include <netinet/in.h>
#include <arpa/inet.h>

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
    va_list args;
    va_start(args, fmt);
    av_log(NULL, level, "[MSwitch] ");
    av_log(NULL, level, fmt, args);
    va_end(args);
}

static int mswitch_parse_sources(MSwitchContext *msw, const char *sources_str)
{
    char *sources_copy = av_strdup(sources_str);
    char *saveptr = NULL;
    char *token;
    int i = 0;
    
    if (!sources_copy) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to allocate memory for sources parsing\n");
        return AVERROR(ENOMEM);
    }
    
    token = av_strtok(sources_copy, ";", &saveptr);
    while (token && i < MSW_MAX_SOURCES) {
        char *eq_pos = strchr(token, '=');
        if (eq_pos) {
            *eq_pos = '\0';
            msw->sources[i].id = av_strdup(token);
            msw->sources[i].url = av_strdup(eq_pos + 1);
            msw->sources[i].name = av_strdup(token); // Default name to ID
            msw->sources[i].latency_ms = 0;
            msw->sources[i].loop = 0;
            msw->sources[i].is_healthy = 1;
            msw->sources[i].last_packet_time = 0;
            msw->sources[i].last_health_check = 0;
            msw->sources[i].stream_loss_count = 0;
            msw->sources[i].black_frame_count = 0;
            msw->sources[i].cc_error_count = 0;
            msw->sources[i].cc_errors_per_sec = 0;
            msw->sources[i].pid_loss_count = 0;
            
            // Initialize packet loss tracking
            msw->sources[i].total_packets_expected = 0;
            msw->sources[i].total_packets_received = 0;
            msw->sources[i].packet_loss_window_start = 0;
            msw->sources[i].packets_in_window = 0;
            msw->sources[i].lost_packets_in_window = 0;
            msw->sources[i].current_packet_loss_percent = 0.0f;
            msw->sources[i].buffer_size = MSW_MAX_BUFFER_PACKETS;
            msw->sources[i].thread_running = 0;
            msw->sources[i].fmt_ctx = NULL;
            msw->sources[i].pkt = NULL;
            msw->sources[i].frame = NULL;
            msw->sources[i].packet_fifo = NULL;
            msw->sources[i].frame_fifo = NULL;
            
            pthread_mutex_init(&msw->sources[i].mutex, NULL);
            pthread_cond_init(&msw->sources[i].cond, NULL);
            
            i++;
        }
        token = av_strtok(NULL, ";", &saveptr);
    }
    
    msw->nb_sources = i;
    av_free(sources_copy);
    
    if (i == 0) {
        mswitch_log(msw, AV_LOG_ERROR, "No valid sources found in sources string\n");
        return AVERROR(EINVAL);
    }
    
    mswitch_log(msw, AV_LOG_INFO, "Parsed %d sources\n", i);
    return 0;
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
    
    // Initialize context
    memset(msw, 0, sizeof(MSwitchContext));
    msw->active_source_index = 0;
    msw->last_switch_time = 0;
    msw->switching = 0;
    msw->metrics_enable = 0;
    msw->json_metrics = 0;
    
    // Initialize mutexes and conditions
    pthread_mutex_init(&msw->state_mutex, NULL);
    pthread_cond_init(&msw->switch_cond, NULL);
    
    // Parse sources from options context (we'll add this to OptionsContext later)
    // For now, we'll use placeholder values
    const char *sources_str = "s0=file:input1.mp4;s1=file:input2.mp4";
    ret = mswitch_parse_sources(msw, sources_str);
    if (ret < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to parse sources\n");
        return ret;
    }
    
    // Set default values
    msw->ingest_mode = MSW_INGEST_HOT;
    msw->mode = MSW_MODE_GRACEFUL;
    msw->buffer_ms = MSW_DEFAULT_BUFFER_MS;
    msw->on_cut = MSW_ON_CUT_FREEZE;
    msw->freeze_on_cut_ms = 2000;
    msw->force_layout = 0;
    
    // Initialize webhook
    msw->webhook.enable = 0;
    msw->webhook.port = 8099;
    msw->webhook.methods = av_strdup("switch,health,config");
    msw->webhook.server_running = 0;
    
    // Initialize CLI
    msw->cli.enable = 0;
    msw->cli.cli_running = 0;
    
    // Initialize auto failover
    msw->auto_failover.enable = 0;
    msw->auto_failover.health_window_ms = MSW_DEFAULT_HEALTH_WINDOW_MS;
    
    // Initialize revert policy
    msw->revert.policy = MSW_REVERT_AUTO;
    msw->revert.health_window_ms = MSW_DEFAULT_HEALTH_WINDOW_MS;
    
    mswitch_log(msw, AV_LOG_INFO, "MSwitch initialized with %d sources\n", msw->nb_sources);
    return 0;
}

int mswitch_cleanup(MSwitchContext *msw)
{
    int i;
    
    // Stop all threads
    mswitch_stop(msw);
    
    // Cleanup sources
    for (i = 0; i < msw->nb_sources; i++) {
        MSwitchSource *src = &msw->sources[i];
        
        av_freep(&src->id);
        av_freep(&src->url);
        av_freep(&src->name);
        
        if (src->fmt_ctx) {
            avformat_close_input(&src->fmt_ctx);
        }
        
        if (src->pkt) {
            av_packet_free(&src->pkt);
        }
        
        if (src->frame) {
            av_frame_free(&src->frame);
        }
        
        if (src->packet_fifo) {
            av_fifo_freep2(&src->packet_fifo);
        }
        
        if (src->frame_fifo) {
            av_fifo_freep2(&src->frame_fifo);
        }
        
        pthread_mutex_destroy(&src->mutex);
        pthread_cond_destroy(&src->cond);
    }
    
    // Cleanup webhook
    av_freep(&msw->webhook.methods);
    
    // Cleanup mutexes
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

// Placeholder implementations for webhook and CLI
int mswitch_webhook_start(MSwitchContext *msw)
{
    mswitch_log(msw, AV_LOG_INFO, "Webhook server started on port %d\n", msw->webhook.port);
    msw->webhook.server_running = 1;
    return 0;
}

int mswitch_webhook_stop(MSwitchContext *msw)
{
    mswitch_log(msw, AV_LOG_INFO, "Webhook server stopped\n");
    msw->webhook.server_running = 0;
    return 0;
}

int mswitch_webhook_handle_request(MSwitchContext *msw, const char *json_request, char **json_response)
{
    // Placeholder for webhook request handling
    *json_response = av_strdup("{\"status\":\"ok\"}");
    return 0;
}

int mswitch_cli_start(MSwitchContext *msw)
{
    mswitch_log(msw, AV_LOG_INFO, "CLI interface started\n");
    msw->cli.cli_running = 1;
    return 0;
}

int mswitch_cli_stop(MSwitchContext *msw)
{
    mswitch_log(msw, AV_LOG_INFO, "CLI interface stopped\n");
    msw->cli.cli_running = 0;
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
