/*
 * SRT ABR (Adaptive Bitrate) Input Switching
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

#ifndef AVFORMAT_SRT_ABR_SWITCH_H
#define AVFORMAT_SRT_ABR_SWITCH_H

#include "avformat.h"
#include "url.h"
#include "srt_bandwidth.h"

#define MAX_SRT_ABR_INPUTS 8

/**
 * Input stream information for ABR switching
 */
typedef struct SRTABRInput {
    URLContext *url_context;       // SRT URL context
    char url[1024];                // Input URL
    int64_t target_bitrate;        // Target bitrate for this input
    SRTNetworkStats last_stats;    // Last network statistics
    int is_active;                 // Currently active
    int is_healthy;                // Connection health status
    int64_t last_health_check;     // Last health check timestamp
    int consecutive_failures;      // Consecutive health check failures
} SRTABRInput;

/**
 * SRT ABR Switching Context
 */
typedef struct SRTABRContext {
    int num_inputs;
    SRTABRInput inputs[MAX_SRT_ABR_INPUTS];
    int current_input_idx;
    int seamless_switching;        // Use seamless switching vs hard switch
    
    // Health check parameters
    double max_loss_rate;          // Max acceptable loss rate (%)
    double max_rtt_ms;             // Max acceptable RTT (ms)
    int64_t max_unrecovered;       // Max unrecovered packets
    int64_t health_check_interval; // Interval between health checks (us)
    int failures_before_switch;    // Number of failures before switching
    
    // Switching policy
    int prefer_higher_quality;     // Prefer higher bitrate when conditions allow
    int64_t switch_cooldown_us;    // Minimum time between switches
    int64_t last_switch_time;      // Last switch timestamp
    
    // Statistics
    int total_switches;
    int health_triggered_switches;
    int quality_triggered_switches;
} SRTABRContext;

/**
 * Initialize SRT ABR context
 */
SRTABRContext *srt_abr_init(void);

/**
 * Add input to ABR context
 * @param ctx ABR context
 * @param url Input URL
 * @param target_bitrate Target bitrate for this input (0 = auto-detect)
 * @return Input index or negative on error
 */
int srt_abr_add_input(SRTABRContext *ctx, const char *url, int64_t target_bitrate);

/**
 * Open all inputs
 * @param ctx ABR context
 * @param options Options to pass to URL open
 * @return 0 on success, negative on error
 */
int srt_abr_open_inputs(SRTABRContext *ctx, AVDictionary **options);

/**
 * Perform health check on all inputs
 * @param ctx ABR context
 * @return 0 on success, negative on error
 */
int srt_abr_health_check(SRTABRContext *ctx);

/**
 * Evaluate and potentially switch to better input
 * @param ctx ABR context
 * @param force_switch Force switch even if current is healthy
 * @return New input index if switched, current index otherwise, negative on error
 */
int srt_abr_evaluate_switch(SRTABRContext *ctx, int force_switch);

/**
 * Read packet from current active input
 * @param ctx ABR context
 * @param buf Buffer to read into
 * @param size Buffer size
 * @return Number of bytes read or negative on error
 */
int srt_abr_read(SRTABRContext *ctx, uint8_t *buf, int size);

/**
 * Get current active input
 * @param ctx ABR context
 * @return Current input context or NULL
 */
URLContext *srt_abr_get_current_input(SRTABRContext *ctx);

/**
 * Get statistics for all inputs
 * @param ctx ABR context
 * @param input_idx Input index (-1 for current)
 * @param stats Output statistics
 * @return 0 on success, negative on error
 */
int srt_abr_get_input_stats(SRTABRContext *ctx, int input_idx, SRTNetworkStats *stats);

/**
 * Close all inputs and free context
 */
void srt_abr_close(SRTABRContext *ctx);

#endif /* AVFORMAT_SRT_ABR_SWITCH_H */

