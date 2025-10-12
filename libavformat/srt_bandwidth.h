/*
 * SRT Bandwidth Monitoring and Reporting
 * Copyright (c) 2025
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 */

#ifndef AVFORMAT_SRT_BANDWIDTH_H
#define AVFORMAT_SRT_BANDWIDTH_H

#include <stdint.h>
#include <srt/srt.h>

/**
 * SRT Network Statistics
 */
typedef struct SRTNetworkStats {
    // Bandwidth metrics
    double bandwidth_mbps;           // Current bandwidth estimate (Mbps)
    double send_rate_mbps;           // Current send rate (Mbps)
    
    // Loss metrics
    double packet_loss_rate;         // Packet loss rate (percentage)
    int64_t packets_sent_total;      // Total packets sent
    int64_t packets_lost_total;      // Total packets lost
    int64_t packets_retransmitted;   // Packets retransmitted
    int64_t packets_dropped;         // Packets dropped
    
    // RTT metrics
    double rtt_ms;                   // Round trip time (milliseconds)
    double rtt_variance_ms;          // RTT variance
    
    // Buffer metrics
    int send_buffer_available;       // Available send buffer (bytes)
    int send_buffer_size;            // Total send buffer size (bytes)
    int recv_buffer_available;       // Available receive buffer (bytes)
    int recv_buffer_size;            // Total receive buffer size (bytes)
    int packets_in_flight;           // Packets currently in flight
    
    // Connection health
    int is_connected;                // Connection status
    int64_t connection_time_ms;      // Connection uptime (milliseconds)
    
    // Unrecovered packets (critical for ABR switching)
    int64_t packets_unrecovered;     // Packets that couldn't be recovered
    
} SRTNetworkStats;

/**
 * Bandwidth quality assessment
 */
typedef enum {
    SRT_BW_EXCELLENT = 0,  // >95% of available bandwidth, <0.1% loss
    SRT_BW_GOOD,           // >80% of available bandwidth, <1% loss  
    SRT_BW_FAIR,           // >50% of available bandwidth, <5% loss
    SRT_BW_POOR,           // >30% of available bandwidth, <10% loss
    SRT_BW_CRITICAL        // <30% of available bandwidth or >10% loss
} SRTBandwidthQuality;

/**
 * Get current network statistics from SRT socket
 * @param fd SRT socket descriptor
 * @param stats Pointer to stats structure to fill
 * @return 0 on success, negative on error
 */
int srt_get_network_stats(SRTSOCKET fd, SRTNetworkStats *stats);

/**
 * Assess overall bandwidth quality
 * @param stats Network statistics
 * @return Quality assessment
 */
SRTBandwidthQuality srt_assess_bandwidth_quality(const SRTNetworkStats *stats);

/**
 * Calculate recommended bitrate based on network conditions
 * @param stats Network statistics
 * @param current_bitrate Current encoder bitrate (bps)
 * @param min_bitrate Minimum allowed bitrate (bps)
 * @param max_bitrate Maximum allowed bitrate (bps)
 * @return Recommended bitrate (bps)
 */
int64_t srt_calculate_recommended_bitrate(const SRTNetworkStats *stats,
                                          int64_t current_bitrate,
                                          int64_t min_bitrate,
                                          int64_t max_bitrate);

/**
 * Check if connection health is acceptable
 * @param stats Network statistics
 * @param max_loss_rate Maximum acceptable loss rate (percentage)
 * @param max_rtt_ms Maximum acceptable RTT (milliseconds)
 * @return 1 if healthy, 0 if unhealthy
 */
int srt_connection_is_healthy(const SRTNetworkStats *stats,
                              double max_loss_rate,
                              double max_rtt_ms);

// Global stats access for encoder rate control
int ff_srt_get_last_stats(SRTNetworkStats *stats);

#endif /* AVFORMAT_SRT_BANDWIDTH_H */

