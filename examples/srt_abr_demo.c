/*
 * SRT ABR (Adaptive Bitrate) Switching Demo
 * Demonstrates automatic switching between multiple SRT inputs
 */

#include <libavformat/avformat.h>
#include <libavformat/srt_abr_switch.h>
#include <libavutil/time.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>

static int running = 1;

static void signal_handler(int sig)
{
    (void)sig;
    running = 0;
}

static const char *quality_str(SRTBandwidthQuality quality)
{
    switch (quality) {
    case SRT_BW_EXCELLENT: return "EXCELLENT";
    case SRT_BW_GOOD: return "GOOD";
    case SRT_BW_FAIR: return "FAIR";
    case SRT_BW_POOR: return "POOR";
    case SRT_BW_CRITICAL: return "CRITICAL";
    default: return "UNKNOWN";
    }
}

int main(int argc, char *argv[])
{
    SRTABRContext *abr = NULL;
    FILE *output = NULL;
    uint8_t buffer[4096];
    int ret, i;
    int64_t total_bytes = 0;
    int64_t start_time;
    
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <output_file> <input1_url> [input2_url] [input3_url] ...\n", argv[0]);
        fprintf(stderr, "Example: %s output.ts \"srt://source1:4200\" \"srt://source2:4201\" \"srt://source3:4202\"\n", argv[0]);
        fprintf(stderr, "\nInputs should be sorted by bitrate (lowest to highest)\n");
        return 1;
    }
    
    const char *output_file = argv[1];
    int num_inputs = argc - 2;
    
    if (num_inputs > MAX_SRT_ABR_INPUTS) {
        fprintf(stderr, "Too many inputs (max: %d)\n", MAX_SRT_ABR_INPUTS);
        return 1;
    }
    
    // Install signal handler
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Initialize ABR context
    abr = srt_abr_init();
    if (!abr) {
        fprintf(stderr, "Failed to initialize ABR context\n");
        return 1;
    }
    
    // Configure ABR parameters
    abr->max_loss_rate = 5.0;           // 5% max loss
    abr->max_rtt_ms = 300.0;            // 300ms max RTT
    abr->max_unrecovered = 500;         // 500 unrecovered packets
    abr->failures_before_switch = 3;    // 3 failures before switch
    abr->prefer_higher_quality = 1;     // Prefer higher quality when possible
    
    // Add inputs
    printf("Adding %d SRT inputs:\n", num_inputs);
    for (i = 0; i < num_inputs; i++) {
        const char *url = argv[2 + i];
        // Assume bitrates: 1M, 3M, 5M, 8M, etc.
        int64_t bitrate = (i + 1) * 1000000 + (i * 2000000);
        
        ret = srt_abr_add_input(abr, url, bitrate);
        if (ret < 0) {
            fprintf(stderr, "Failed to add input %d: %s\n", i, url);
            goto cleanup;
        }
        
        printf("  [%d] %s (target: %.1f Mbps)\n", i, url, bitrate / 1000000.0);
    }
    
    // Open all inputs
    printf("\nOpening inputs...\n");
    ret = srt_abr_open_inputs(abr, NULL);
    if (ret < 0) {
        fprintf(stderr, "Failed to open inputs\n");
        goto cleanup;
    }
    
    // Open output file
    output = fopen(output_file, "wb");
    if (!output) {
        fprintf(stderr, "Failed to open output file: %s\n", output_file);
        goto cleanup;
    }
    
    printf("\nStarting ABR streaming:\n");
    printf("  Output: %s\n", output_file);
    printf("  Active input: %d\n", abr->current_input_idx);
    printf("\nHealth thresholds:\n");
    printf("  Max loss rate: %.1f%%\n", abr->max_loss_rate);
    printf("  Max RTT: %.0f ms\n", abr->max_rtt_ms);
    printf("  Max unrecovered: %lld packets\n", abr->max_unrecovered);
    printf("\nPress Ctrl+C to stop...\n\n");
    
    start_time = av_gettime_relative();
    
    // Main streaming loop
    while (running) {
        ret = srt_abr_read(abr, buffer, sizeof(buffer));
        
        if (ret < 0) {
            if (ret == AVERROR(EAGAIN)) {
                av_usleep(10000);  // 10ms
                continue;
            }
            fprintf(stderr, "Read error: %s\n", av_err2str(ret));
            break;
        }
        
        if (ret == 0)  // EOF
            break;
        
        // Write to output
        fwrite(buffer, 1, ret, output);
        total_bytes += ret;
        
        // Print status every 5 seconds
        static int64_t last_status_time = 0;
        int64_t current_time = av_gettime_relative();
        
        if (current_time - last_status_time > 5000000) {  // 5 seconds
            last_status_time = current_time;
            
            int64_t elapsed = (current_time - start_time) / 1000000;  // seconds
            double mbps = (total_bytes * 8.0) / (elapsed * 1000000.0);
            
            SRTNetworkStats stats;
            if (srt_abr_get_input_stats(abr, -1, &stats) == 0) {
                SRTBandwidthQuality quality = srt_assess_bandwidth_quality(&stats);
                
                printf("[%02lld:%02lld] Input %d | %.2f Mbps | "
                       "BW: %.1f Mbps | Loss: %.2f%% | RTT: %.0f ms | "
                       "Unrecovered: %lld | Quality: %s%s\n",
                       elapsed / 60, elapsed % 60,
                       abr->current_input_idx,
                       mbps,
                       stats.bandwidth_mbps,
                       stats.packet_loss_rate,
                       stats.rtt_ms,
                       stats.packets_unrecovered,
                       quality_str(quality),
                       stats.is_connected ? "" : " [DISCONNECTED]");
            }
        }
    }
    
    printf("\n\nStreaming complete!\n");
    printf("Statistics:\n");
    printf("  Total bytes received: %lld (%.2f MB)\n", 
           total_bytes, total_bytes / (1024.0 * 1024.0));
    printf("  Total switches: %d\n", abr->total_switches);
    printf("  Health-triggered: %d\n", abr->health_triggered_switches);
    printf("  Quality-triggered: %d\n", abr->quality_triggered_switches);
    
    int64_t elapsed = (av_gettime_relative() - start_time) / 1000000;
    if (elapsed > 0) {
        double avg_mbps = (total_bytes * 8.0) / (elapsed * 1000000.0);
        printf("  Average bitrate: %.2f Mbps\n", avg_mbps);
    }
    
    // Print per-input statistics
    printf("\nPer-input statistics:\n");
    for (i = 0; i < abr->num_inputs; i++) {
        SRTNetworkStats stats;
        if (srt_abr_get_input_stats(abr, i, &stats) == 0) {
            printf("  [%d] %s\n", i, abr->inputs[i].is_healthy ? "HEALTHY" : "UNHEALTHY");
            printf("      BW: %.1f Mbps | Loss: %.2f%% | RTT: %.0f ms | "
                   "Unrecovered: %lld\n",
                   stats.bandwidth_mbps,
                   stats.packet_loss_rate,
                   stats.rtt_ms,
                   stats.packets_unrecovered);
        }
    }
    
cleanup:
    if (output) fclose(output);
    if (abr) srt_abr_close(abr);
    
    return 0;
}

