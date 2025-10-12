/*
 * SRT-based Real-Time Rate Control for Video Encoders
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
 */

#include "srt_rate_control.h"
#include "libavutil/log.h"
#include "libavutil/time.h"
#include "libavutil/opt.h"
#include "libavutil/mem.h"
#include "libavformat/url.h"
#include <string.h>

#define DEFAULT_UPDATE_INTERVAL_US 1000000  // 1 second
#define EMERGENCY_LOSS_THRESHOLD 15.0       // 15% packet loss
#define EMERGENCY_BITRATE_FACTOR 0.5        // Drop to 50% in emergency

// Forward declaration of libsrt context access
extern int ff_srt_get_stats(URLContext *h, SRTNetworkStats *stats);

SRTRateControl *srt_rc_init(AVCodecContext *avctx,
                            int64_t min_bitrate,
                            int64_t max_bitrate)
{
    SRTRateControl *rc = av_mallocz(sizeof(*rc));
    if (!rc)
        return NULL;
    
    rc->avctx = avctx;
    rc->min_bitrate = min_bitrate > 0 ? min_bitrate : 500000;  // 500 kbps default min
    rc->max_bitrate = max_bitrate > 0 ? max_bitrate : avctx->bit_rate;
    rc->current_bitrate = avctx->bit_rate;
    rc->target_bitrate = avctx->bit_rate;
    rc->update_interval_us = DEFAULT_UPDATE_INTERVAL_US;
    rc->last_update_time = 0;
    rc->enabled = 1;
    rc->emergency_mode = 0;
    
    av_log(avctx, AV_LOG_INFO, "SRT Rate Control initialized: "
           "bitrate %"PRId64" (min: %"PRId64", max: %"PRId64")\n",
           rc->current_bitrate, rc->min_bitrate, rc->max_bitrate);
    
    return rc;
}

void srt_rc_set_url_context(SRTRateControl *rc, void *url_context)
{
    if (rc)
        rc->srt_url_context = url_context;
}

int srt_rc_get_stats(SRTRateControl *rc, SRTNetworkStats *stats)
{
    if (!rc || !rc->srt_url_context || !stats)
        return -1;
    
    // Get stats from SRT URL context
    URLContext *h = (URLContext *)rc->srt_url_context;
    return ff_srt_get_stats(h, stats);
}

int srt_rc_update(SRTRateControl *rc)
{
    SRTNetworkStats stats;
    int64_t current_time;
    int64_t recommended_bitrate;
    
    if (!rc || !rc->enabled)
        return 0;
    
    current_time = av_gettime_relative();
    
    // Check if it's time to update
    if (current_time - rc->last_update_time < rc->update_interval_us)
        return 0;
    
    rc->last_update_time = current_time;
    
    // Get current network statistics
    if (srt_rc_get_stats(rc, &stats) < 0) {
        av_log(rc->avctx, AV_LOG_DEBUG, "SRT RC: Failed to get network stats\n");
        return -1;
    }
    
    // Check for emergency conditions
    if (stats.packet_loss_rate > EMERGENCY_LOSS_THRESHOLD && !rc->emergency_mode) {
        rc->emergency_mode = 1;
        rc->target_bitrate = (int64_t)(rc->current_bitrate * EMERGENCY_BITRATE_FACTOR);
        av_log(rc->avctx, AV_LOG_WARNING, 
               "SRT RC: Emergency mode activated (loss: %.2f%%), "
               "reducing bitrate to %"PRId64"\n",
               stats.packet_loss_rate, rc->target_bitrate);
    } else if (stats.packet_loss_rate < 5.0 && rc->emergency_mode) {
        // Exit emergency mode when conditions improve
        rc->emergency_mode = 0;
        av_log(rc->avctx, AV_LOG_INFO, "SRT RC: Emergency mode deactivated\n");
    }
    
    // Calculate recommended bitrate based on network conditions
    recommended_bitrate = srt_calculate_recommended_bitrate(&stats,
                                                            rc->current_bitrate,
                                                            rc->min_bitrate,
                                                            rc->max_bitrate);
    
    // Update target if it changed significantly (>5% difference)
    int64_t diff = recommended_bitrate > rc->target_bitrate ?
                   recommended_bitrate - rc->target_bitrate :
                   rc->target_bitrate - recommended_bitrate;
    
    if (diff > rc->target_bitrate / 20) {  // >5% change
        int64_t old_bitrate = rc->target_bitrate;
        rc->target_bitrate = recommended_bitrate;
        rc->adjustment_count++;
        
        if (recommended_bitrate > old_bitrate) {
            rc->increase_count++;
            av_log(rc->avctx, AV_LOG_INFO,
                   "SRT RC: Increasing bitrate %"PRId64" → %"PRId64" "
                   "(BW: %.2f Mbps, Loss: %.2f%%, RTT: %.1f ms)\n",
                   old_bitrate, recommended_bitrate,
                   stats.bandwidth_mbps, stats.packet_loss_rate, stats.rtt_ms);
        } else {
            rc->decrease_count++;
            av_log(rc->avctx, AV_LOG_INFO,
                   "SRT RC: Decreasing bitrate %"PRId64" → %"PRId64" "
                   "(BW: %.2f Mbps, Loss: %.2f%%, RTT: %.1f ms)\n",
                   old_bitrate, recommended_bitrate,
                   stats.bandwidth_mbps, stats.packet_loss_rate, stats.rtt_ms);
        }
    }
    
    return 0;
}

int srt_rc_apply(SRTRateControl *rc)
{
    if (!rc || !rc->enabled || !rc->avctx)
        return 0;
    
    // Only apply if target differs from current
    if (rc->target_bitrate == rc->current_bitrate)
        return 0;
    
    AVCodecContext *avctx = rc->avctx;
    
    // Update encoder parameters
    // Note: This requires encoder support for dynamic bitrate changes
    // x264 supports this via its TCP control interface
    // For other encoders, this may require reopening the encoder
    
    avctx->bit_rate = rc->target_bitrate;
    avctx->rc_max_rate = rc->target_bitrate;
    avctx->rc_buffer_size = rc->target_bitrate * 2;  // 2-second buffer
    
    // For x264, we would also send TCP commands if tcp-port is enabled
    // This is handled separately in the encoder wrapper
    
    rc->current_bitrate = rc->target_bitrate;
    
    return 0;
}

void srt_rc_enable(SRTRateControl *rc, int enable)
{
    if (rc) {
        rc->enabled = enable;
        av_log(rc->avctx, AV_LOG_INFO, "SRT Rate Control %s\n",
               enable ? "enabled" : "disabled");
    }
}

int srt_rc_is_enabled(SRTRateControl *rc)
{
    return rc ? rc->enabled : 0;
}

void srt_rc_free(SRTRateControl *rc)
{
    if (!rc)
        return;
    
    av_log(rc->avctx, AV_LOG_INFO,
           "SRT RC: Session stats - Total adjustments: %d "
           "(increases: %d, decreases: %d)\n",
           rc->adjustment_count, rc->increase_count, rc->decrease_count);
    
    av_free(rc);
}

