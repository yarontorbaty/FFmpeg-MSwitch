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

#ifndef AVCODEC_SRT_RATE_CONTROL_H
#define AVCODEC_SRT_RATE_CONTROL_H

#include "avcodec.h"
#include "libavformat/srt_bandwidth.h"

/**
 * SRT Rate Control Context
 * Monitors SRT network conditions and adjusts encoder bitrate
 */
typedef struct SRTRateControl {
    AVCodecContext *avctx;
    
    // SRT monitoring (URL context passed from output)
    void *srt_url_context;  // URLContext from libavformat
    
    // Rate control parameters
    int64_t min_bitrate;
    int64_t max_bitrate;
    int64_t current_bitrate;
    int64_t target_bitrate;
    
    // Update intervals
    int64_t update_interval_us;  // Microseconds between updates
    int64_t last_update_time;
    
    // Statistics
    int adjustment_count;
    int increase_count;
    int decrease_count;
    
    // State
    int enabled;
    int emergency_mode;  // Triggered on severe packet loss
    
} SRTRateControl;

/**
 * Initialize SRT rate control
 * @param avctx Encoder context
 * @param min_bitrate Minimum allowed bitrate (bps)
 * @param max_bitrate Maximum allowed bitrate (bps)
 * @return Allocated rate control context or NULL on error
 */
SRTRateControl *srt_rc_init(AVCodecContext *avctx,
                            int64_t min_bitrate,
                            int64_t max_bitrate);

/**
 * Associate SRT URL context for monitoring
 * @param rc Rate control context
 * @param url_context URLContext from libavformat (SRT output)
 */
void srt_rc_set_url_context(SRTRateControl *rc, void *url_context);

/**
 * Update rate control based on current network conditions
 * Should be called periodically (e.g., before encoding each frame)
 * @param rc Rate control context
 * @return 0 on success, negative on error
 */
int srt_rc_update(SRTRateControl *rc);

/**
 * Apply rate control adjustments to encoder
 * @param rc Rate control context
 * @return 0 on success, negative on error
 */
int srt_rc_apply(SRTRateControl *rc);

/**
 * Get current network statistics
 * @param rc Rate control context
 * @param stats Pointer to stats structure to fill
 * @return 0 on success, negative on error
 */
int srt_rc_get_stats(SRTRateControl *rc, SRTNetworkStats *stats);

/**
 * Enable/disable rate control
 */
void srt_rc_enable(SRTRateControl *rc, int enable);

/**
 * Check if rate control is enabled
 */
int srt_rc_is_enabled(SRTRateControl *rc);

/**
 * Cleanup and free rate control context
 */
void srt_rc_free(SRTRateControl *rc);

#endif /* AVCODEC_SRT_RATE_CONTROL_H */

