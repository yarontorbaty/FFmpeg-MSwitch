/*
 * SRT ABR (Adaptive Bitrate) Input Switching
 * Copyright (c) 2025
 *
 * This file is part of FFmpeg.
 */

#include "srt_abr_switch.h"
#include "libavutil/avstring.h"
#include "libavutil/log.h"
#include "libavutil/time.h"
#include "libavutil/mem.h"
#include "avio.h"
#include "url.h"
#include <string.h>

// External function from libsrt.c
int ff_srt_get_stats(URLContext *h, SRTNetworkStats *stats);

#define DEFAULT_MAX_LOSS_RATE 5.0
#define DEFAULT_MAX_RTT_MS 300.0
#define DEFAULT_MAX_UNRECOVERED 500
#define DEFAULT_HEALTH_CHECK_INTERVAL_US 2000000  // 2 seconds
#define DEFAULT_FAILURES_BEFORE_SWITCH 3
#define DEFAULT_SWITCH_COOLDOWN_US 5000000  // 5 seconds

SRTABRContext *srt_abr_init(void)
{
    SRTABRContext *ctx = av_mallocz(sizeof(*ctx));
    if (!ctx)
        return NULL;
    
    ctx->num_inputs = 0;
    ctx->current_input_idx = 0;
    ctx->seamless_switching = 1;
    
    ctx->max_loss_rate = DEFAULT_MAX_LOSS_RATE;
    ctx->max_rtt_ms = DEFAULT_MAX_RTT_MS;
    ctx->max_unrecovered = DEFAULT_MAX_UNRECOVERED;
    ctx->health_check_interval = DEFAULT_HEALTH_CHECK_INTERVAL_US;
    ctx->failures_before_switch = DEFAULT_FAILURES_BEFORE_SWITCH;
    
    ctx->prefer_higher_quality = 1;
    ctx->switch_cooldown_us = DEFAULT_SWITCH_COOLDOWN_US;
    ctx->last_switch_time = 0;
    
    return ctx;
}

int srt_abr_add_input(SRTABRContext *ctx, const char *url, int64_t target_bitrate)
{
    SRTABRInput *input;
    
    if (!ctx || !url || ctx->num_inputs >= MAX_SRT_ABR_INPUTS)
        return -1;
    
    input = &ctx->inputs[ctx->num_inputs];
    av_strlcpy(input->url, url, sizeof(input->url));
    input->target_bitrate = target_bitrate;
    input->is_active = 0;
    input->is_healthy = 0;
    input->consecutive_failures = 0;
    input->url_context = NULL;
    
    return ctx->num_inputs++;
}

int srt_abr_open_inputs(SRTABRContext *ctx, AVDictionary **options)
{
    int i, ret;
    
    if (!ctx || ctx->num_inputs == 0)
        return -1;
    
    // Open all inputs
    for (i = 0; i < ctx->num_inputs; i++) {
        SRTABRInput *input = &ctx->inputs[i];
        
        ret = ffurl_open_whitelist(&input->url_context, input->url, AVIO_FLAG_READ,
                                  NULL, options, NULL, NULL, NULL);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Failed to open SRT input %d (%s): %s\n",
                   i, input->url, av_err2str(ret));
            input->is_healthy = 0;
            continue;
        }
        
        input->is_healthy = 1;
        av_log(NULL, AV_LOG_INFO, "Opened SRT ABR input %d: %s (bitrate: %"PRId64")\n",
               i, input->url, input->target_bitrate);
    }
    
    // Activate first healthy input
    for (i = 0; i < ctx->num_inputs; i++) {
        if (ctx->inputs[i].is_healthy) {
            ctx->inputs[i].is_active = 1;
            ctx->current_input_idx = i;
            av_log(NULL, AV_LOG_INFO, "Activated initial input %d\n", i);
            break;
        }
    }
    
    if (i >= ctx->num_inputs) {
        av_log(NULL, AV_LOG_ERROR, "No healthy inputs available\n");
        return AVERROR(EIO);
    }
    
    return 0;
}

int srt_abr_health_check(SRTABRContext *ctx)
{
    int i;
    int64_t current_time = av_gettime_relative();
    
    if (!ctx)
        return -1;
    
    for (i = 0; i < ctx->num_inputs; i++) {
        SRTABRInput *input = &ctx->inputs[i];
        
        if (!input->url_context)
            continue;
        
        // Check if it's time for health check
        if (current_time - input->last_health_check < ctx->health_check_interval)
            continue;
        
        input->last_health_check = current_time;
        
        // Get network statistics
        if (ff_srt_get_stats(input->url_context, &input->last_stats) < 0) {
            input->consecutive_failures++;
            input->is_healthy = 0;
            continue;
        }
        
        // Evaluate health
        int is_healthy = srt_connection_is_healthy(&input->last_stats,
                                                   ctx->max_loss_rate,
                                                   ctx->max_rtt_ms);
        
        // Also check unrecovered packets
        if (input->last_stats.packets_unrecovered > ctx->max_unrecovered)
            is_healthy = 0;
        
        if (is_healthy) {
            input->consecutive_failures = 0;
            input->is_healthy = 1;
        } else {
            input->consecutive_failures++;
            if (input->consecutive_failures >= ctx->failures_before_switch) {
                input->is_healthy = 0;
                av_log(NULL, AV_LOG_WARNING,
                       "Input %d marked unhealthy (loss: %.2f%%, RTT: %.1fms, "
                       "unrecovered: %"PRId64")\n",
                       i, input->last_stats.packet_loss_rate,
                       input->last_stats.rtt_ms,
                       input->last_stats.packets_unrecovered);
            }
        }
    }
    
    return 0;
}

int srt_abr_evaluate_switch(SRTABRContext *ctx, int force_switch)
{
    int i, best_idx;
    int64_t current_time;
    int64_t best_bitrate;
    SRTABRInput *current, *candidate;
    
    if (!ctx || ctx->num_inputs <= 1)
        return ctx->current_input_idx;
    
    current_time = av_gettime_relative();
    current = &ctx->inputs[ctx->current_input_idx];
    
    // Check cooldown period
    if (!force_switch && 
        current_time - ctx->last_switch_time < ctx->switch_cooldown_us) {
        return ctx->current_input_idx;
    }
    
    // If current is unhealthy, force switch
    if (!current->is_healthy) {
        force_switch = 1;
        av_log(NULL, AV_LOG_WARNING,
               "Current input %d is unhealthy, forcing switch\n",
               ctx->current_input_idx);
    }
    
    // Find best alternative
    best_idx = ctx->current_input_idx;
    best_bitrate = current->target_bitrate;
    
    for (i = 0; i < ctx->num_inputs; i++) {
        if (i == ctx->current_input_idx && !force_switch)
            continue;
        
        candidate = &ctx->inputs[i];
        
        if (!candidate->is_healthy || !candidate->url_context)
            continue;
        
        // Decision logic:
        // 1. If current is unhealthy, switch to any healthy input
        // 2. If prefer higher quality and candidate has higher bitrate, switch
        // 3. If candidate is significantly better quality, switch
        
        if (force_switch && candidate->is_healthy) {
            best_idx = i;
            best_bitrate = candidate->target_bitrate;
            break;
        }
        
        if (ctx->prefer_higher_quality && 
            candidate->target_bitrate > best_bitrate) {
            // Check if network can handle higher bitrate
            if (candidate->last_stats.bandwidth_mbps * 1000000 * 0.75 >= 
                candidate->target_bitrate) {
                best_idx = i;
                best_bitrate = candidate->target_bitrate;
            }
        }
    }
    
    // Perform switch if necessary
    if (best_idx != ctx->current_input_idx) {
        int switch_type = force_switch ? 
            (1 /* health */) : (0 /* quality */);
        
        av_log(NULL, AV_LOG_INFO,
               "Switching from input %d to %d (%s switch, bitrate: %"PRId64" → %"PRId64")\n",
               ctx->current_input_idx, best_idx,
               switch_type ? "health-triggered" : "quality-triggered",
               current->target_bitrate, ctx->inputs[best_idx].target_bitrate);
        
        current->is_active = 0;
        ctx->inputs[best_idx].is_active = 1;
        ctx->current_input_idx = best_idx;
        ctx->last_switch_time = current_time;
        ctx->total_switches++;
        
        if (switch_type)
            ctx->health_triggered_switches++;
        else
            ctx->quality_triggered_switches++;
    }
    
    return ctx->current_input_idx;
}

int srt_abr_read(SRTABRContext *ctx, uint8_t *buf, int size)
{
    int ret;
    SRTABRInput *input;
    
    if (!ctx || !buf || size <= 0)
        return AVERROR(EINVAL);
    
    // Perform periodic health check
    srt_abr_health_check(ctx);
    
    // Evaluate and potentially switch inputs
    srt_abr_evaluate_switch(ctx, 0);
    
    input = &ctx->inputs[ctx->current_input_idx];
    
    if (!input->url_context || !input->is_active) {
        av_log(NULL, AV_LOG_ERROR, "No active input available\n");
        return AVERROR(EIO);
    }
    
    ret = ffurl_read(input->url_context, buf, size);
    
    if (ret < 0) {
        av_log(NULL, AV_LOG_WARNING, "Read error from input %d: %s\n",
               ctx->current_input_idx, av_err2str(ret));
        input->consecutive_failures++;
        
        // Try to switch to another input
        if (input->consecutive_failures >= ctx->failures_before_switch) {
            input->is_healthy = 0;
            srt_abr_evaluate_switch(ctx, 1);
        }
    }
    
    return ret;
}

URLContext *srt_abr_get_current_input(SRTABRContext *ctx)
{
    if (!ctx || ctx->current_input_idx < 0 || 
        ctx->current_input_idx >= ctx->num_inputs)
        return NULL;
    
    return ctx->inputs[ctx->current_input_idx].url_context;
}

int srt_abr_get_input_stats(SRTABRContext *ctx, int input_idx, 
                            SRTNetworkStats *stats)
{
    SRTABRInput *input;
    
    if (!ctx || !stats)
        return -1;
    
    if (input_idx < 0)
        input_idx = ctx->current_input_idx;
    
    if (input_idx < 0 || input_idx >= ctx->num_inputs)
        return -1;
    
    input = &ctx->inputs[input_idx];
    
    if (!input->url_context)
        return -1;
    
    return ff_srt_get_stats(input->url_context, stats);
}

void srt_abr_close(SRTABRContext *ctx)
{
    int i;
    
    if (!ctx)
        return;
    
    av_log(NULL, AV_LOG_INFO,
           "SRT ABR: Session stats - Total switches: %d "
           "(health: %d, quality: %d)\n",
           ctx->total_switches,
           ctx->health_triggered_switches,
           ctx->quality_triggered_switches);
    
    for (i = 0; i < ctx->num_inputs; i++) {
        if (ctx->inputs[i].url_context) {
            ffurl_close(ctx->inputs[i].url_context);
            ctx->inputs[i].url_context = NULL;
        }
    }
    
    av_free(ctx);
}

