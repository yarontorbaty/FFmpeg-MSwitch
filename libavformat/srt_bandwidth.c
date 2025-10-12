/*
 * SRT Bandwidth Monitoring and Reporting
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

#include "srt_bandwidth.h"
#include "libavutil/time.h"
#include <string.h>
#include <math.h>

#define SAFETY_MARGIN 0.75  // Use 75% of available bandwidth
#define SMOOTHING_FACTOR 0.3  // Exponential smoothing factor

int srt_get_network_stats(SRTSOCKET fd, SRTNetworkStats *stats)
{
    SRT_TRACEBSTATS perf;
    
    if (!stats)
        return -1;
    
    memset(stats, 0, sizeof(*stats));
    
    // Get SRT performance statistics
    if (srt_bistats(fd, &perf, 1, 1) < 0)
        return -1;
    
    // Connection status
    SRT_SOCKSTATUS status = srt_getsockstate(fd);
    stats->is_connected = (status == SRTS_CONNECTED);
    
    // Bandwidth metrics (convert from Mbps)
    stats->bandwidth_mbps = perf.mbpsBandwidth;
    stats->send_rate_mbps = perf.mbpsSendRate;
    
    // Loss metrics
    if (perf.pktSentTotal > 0) {
        stats->packet_loss_rate = (double)perf.pktSndLossTotal / 
                                 (double)perf.pktSentTotal * 100.0;
    }
    stats->packets_sent_total = perf.pktSentTotal;
    stats->packets_lost_total = perf.pktSndLossTotal;
    stats->packets_retransmitted = perf.pktRetransTotal;
    stats->packets_dropped = perf.pktSndDropTotal;
    
    // Unrecovered packets - critical for ABR
    #ifdef SRT_ENABLE_LOSSINFO
    stats->packets_unrecovered = perf.pktRcvUndecryptTotal;  // Or appropriate field
    #else
    stats->packets_unrecovered = perf.pktSndLossTotal - perf.pktRetransTotal;
    #endif
    
    // RTT metrics (convert from microseconds to milliseconds)
    stats->rtt_ms = perf.msRTT;
    
    // Buffer metrics
    stats->send_buffer_available = perf.byteAvailSndBuf;
    stats->send_buffer_size = perf.byteMSS * 1000; // Approximation
    stats->recv_buffer_available = perf.byteAvailRcvBuf;
    stats->recv_buffer_size = perf.byteMSS * 1000;
    stats->packets_in_flight = perf.pktFlightSize;
    
    // Connection time
    stats->connection_time_ms = perf.msTimeStamp;
    
    return 0;
}

SRTBandwidthQuality srt_assess_bandwidth_quality(const SRTNetworkStats *stats)
{
    if (!stats || !stats->is_connected)
        return SRT_BW_CRITICAL;
    
    double utilization = 0.0;
    if (stats->bandwidth_mbps > 0) {
        utilization = (stats->send_rate_mbps / stats->bandwidth_mbps) * 100.0;
    }
    
    double loss = stats->packet_loss_rate;
    
    // Critical conditions
    if (loss > 10.0 || utilization < 30.0 || stats->packets_unrecovered > 100)
        return SRT_BW_CRITICAL;
    
    // Poor conditions
    if (loss > 5.0 || utilization < 50.0)
        return SRT_BW_POOR;
    
    // Fair conditions
    if (loss > 1.0 || utilization < 80.0)
        return SRT_BW_FAIR;
    
    // Good conditions
    if (loss > 0.1 || utilization < 95.0)
        return SRT_BW_GOOD;
    
    // Excellent conditions
    return SRT_BW_EXCELLENT;
}

int64_t srt_calculate_recommended_bitrate(const SRTNetworkStats *stats,
                                          int64_t current_bitrate,
                                          int64_t min_bitrate,
                                          int64_t max_bitrate)
{
    if (!stats || !stats->is_connected)
        return min_bitrate;
    
    // Convert bandwidth from Mbps to bps
    int64_t available_bw_bps = (int64_t)(stats->bandwidth_mbps * 1000000.0);
    
    // Apply safety margin
    int64_t target_bitrate = (int64_t)(available_bw_bps * SAFETY_MARGIN);
    
    // Adjust based on packet loss
    if (stats->packet_loss_rate > 5.0) {
        // High loss: aggressive reduction
        target_bitrate = (int64_t)(target_bitrate * 0.7);
    } else if (stats->packet_loss_rate > 2.0) {
        // Moderate loss: moderate reduction
        target_bitrate = (int64_t)(target_bitrate * 0.85);
    } else if (stats->packet_loss_rate > 0.5) {
        // Low loss: slight reduction
        target_bitrate = (int64_t)(target_bitrate * 0.95);
    }
    
    // Adjust based on RTT
    if (stats->rtt_ms > 300.0) {
        // High RTT: reduce bitrate
        target_bitrate = (int64_t)(target_bitrate * 0.9);
    } else if (stats->rtt_ms > 200.0) {
        target_bitrate = (int64_t)(target_bitrate * 0.95);
    }
    
    // Adjust based on buffer availability
    if (stats->send_buffer_size > 0) {
        double buffer_util = 1.0 - ((double)stats->send_buffer_available / 
                                    (double)stats->send_buffer_size);
        if (buffer_util > 0.9) {
            // Buffer nearly full: reduce bitrate
            target_bitrate = (int64_t)(target_bitrate * 0.8);
        }
    }
    
    // Apply rate limiting: don't change too quickly
    int64_t max_increase = (int64_t)(current_bitrate * 1.20);  // Max 20% increase
    int64_t max_decrease = (int64_t)(current_bitrate * 0.70);  // Max 30% decrease
    
    if (target_bitrate > current_bitrate && target_bitrate > max_increase) {
        target_bitrate = max_increase;
    } else if (target_bitrate < current_bitrate && target_bitrate < max_decrease) {
        target_bitrate = max_decrease;
    }
    
    // Clamp to min/max bounds
    if (target_bitrate < min_bitrate)
        target_bitrate = min_bitrate;
    if (target_bitrate > max_bitrate)
        target_bitrate = max_bitrate;
    
    return target_bitrate;
}

int srt_connection_is_healthy(const SRTNetworkStats *stats,
                              double max_loss_rate,
                              double max_rtt_ms)
{
    if (!stats || !stats->is_connected)
        return 0;
    
    // Check loss rate
    if (stats->packet_loss_rate > max_loss_rate)
        return 0;
    
    // Check RTT
    if (stats->rtt_ms > max_rtt_ms)
        return 0;
    
    // Check for excessive unrecovered packets
    if (stats->packets_unrecovered > 1000)
        return 0;
    
    // Check bandwidth availability
    if (stats->bandwidth_mbps < 0.5)  // Less than 500 kbps
        return 0;
    
    return 1;
}

