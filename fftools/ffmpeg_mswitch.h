/*
 * Multi-Source Switch (MSwitch) controller for FFmpeg
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 */

#ifndef FFTOOLS_FFMPEG_MSWITCH_H
#define FFTOOLS_FFMPEG_MSWITCH_H

#include "ffmpeg.h"
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/thread.h"
#include "libavutil/fifo.h"

#define MSW_MAX_SOURCES 3
#define MSW_MAX_BUFFER_PACKETS 100
#define MSW_DEFAULT_BUFFER_MS 800
#define MSW_DEFAULT_HEALTH_WINDOW_MS 5000

typedef enum MSwitchMode {
    MSW_MODE_SEAMLESS,
    MSW_MODE_GRACEFUL,
    MSW_MODE_CUTOVER,
} MSwitchMode;

typedef enum MSwitchIngest {
    MSW_INGEST_STANDBY,
    MSW_INGEST_HOT,
} MSwitchIngest;

typedef enum MSwitchRevert {
    MSW_REVERT_AUTO,
    MSW_REVERT_MANUAL,
} MSwitchRevert;

typedef enum MSwitchOnCut {
    MSW_ON_CUT_FREEZE,
    MSW_ON_CUT_BLACK,
} MSwitchOnCut;

typedef struct MSwitchSource {
    char *id;                    // s0, s1, s2
    char *url;                   // source URL
    char *name;                  // human-readable name
    int latency_ms;              // latency offset
    int loop;                    // loop file sources
    
    // Subprocess management for frame-level switching
    pid_t subprocess_pid;        // PID of source FFmpeg process
    int subprocess_stdout;       // stdout pipe from subprocess (raw frames)
    int subprocess_stderr;       // stderr pipe from subprocess
    int subprocess_running;      // Flag indicating if subprocess is active
    char *subprocess_output_url; // UDP URL where subprocess outputs (e.g., "udp://127.0.0.1:12350")
    pthread_t monitor_thread;    // Thread to monitor subprocess health
    
    // Pipe-based frame switching (for graceful/cutover modes)
    int frame_pipe_fd;           // Pipe for raw frame data
    AVFrame *current_frame;      // Current decoded frame
    pthread_mutex_t frame_mutex; // Protect frame access
    
    // Runtime state
    AVFormatContext *fmt_ctx;
    AVCodecContext *dec_ctx[AVMEDIA_TYPE_NB];
    AVPacket *pkt;
    AVFrame *frame;
    int is_healthy;
    int64_t last_packet_time;
    int64_t last_health_check;
    
    // Health metrics
    int stream_loss_count;
    int black_frame_count;
    int cc_error_count;
    int cc_errors_per_sec;
    int pid_loss_count;
    
    // Packet loss tracking
    int64_t total_packets_expected;
    int64_t total_packets_received;
    int64_t packet_loss_window_start;
    int64_t packets_in_window;
    int64_t lost_packets_in_window;
    float current_packet_loss_percent;
    
    // Buffering
    AVFifo *packet_fifo;
    AVFifo *frame_fifo;
    int buffer_size;
    
    // Threading
    pthread_t demux_thread;
    pthread_t decode_thread;
    int thread_running;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} MSwitchSource;

typedef struct MSwitchHealthThresholds {
    int stream_loss_ms;
    int pid_loss_ms;
    int black_ms;
    int cc_errors_per_sec;        // CC errors per second
    float packet_loss_percent;    // Packet loss percentage threshold
    int packet_loss_window_sec;  // Window for measuring packet loss
} MSwitchHealthThresholds;

typedef struct MSwitchWebhook {
    int enable;
    int port;
    char *methods;  // comma-separated: switch,health,config
    pthread_t server_thread;
    int server_running;
} MSwitchWebhook;

typedef struct MSwitchCLI {
    int enable;
    pthread_t cli_thread;
    int cli_running;
} MSwitchCLI;

typedef struct MSwitchAuto {
    int enable;
    MSwitchHealthThresholds thresholds;
    int health_window_ms;
} MSwitchAuto;

typedef struct MSwitchRevertPolicy {
    MSwitchRevert policy;
    int health_window_ms;
} MSwitchRevertPolicy;

typedef struct MSwitchContext {
    // Configuration
    int enable;
    MSwitchSource sources[MSW_MAX_SOURCES];
    int nb_sources;
    MSwitchIngest ingest_mode;
    MSwitchMode mode;
    int buffer_ms;
    MSwitchOnCut on_cut;
    int freeze_on_cut_ms;
    int force_layout;
    
    // Control interfaces
    MSwitchWebhook webhook;
    MSwitchCLI cli;
    MSwitchAuto auto_failover;
    MSwitchRevertPolicy revert;
    
    // Runtime state
    int active_source_index;
    int64_t last_switch_time;
    int switching;
    
    // Filter-based switching
    void *streamselect_ctx;        // AVFilterContext* for streamselect filter
    void *filter_graph;            // AVFilterGraph* that contains streamselect
    
    // Mode-specific management
    int frame_switching_enabled;   // True for graceful/cutover modes
    int packet_switching_enabled;  // True for seamless mode
    int standby_mode_enabled;      // True for standby ingest
    
    // Frame switching infrastructure (graceful/cutover modes)
    AVFrame *output_frame;         // Current output frame
    pthread_t frame_switch_thread; // Thread to handle frame switching
    pthread_mutex_t output_mutex;  // Protect output frame
    pthread_cond_t frame_ready_cond; // Signal when frame is ready
    
    // Packet switching infrastructure (seamless mode)
    pthread_t packet_switch_thread; // Thread to handle packet switching
    
    // Subprocess management
    int base_udp_port;             // Base port for subprocess UDP outputs (seamless mode)
    AVFormatContext *active_input; // Input context for currently active subprocess
    pthread_t switch_thread;       // Thread to handle source switching
    int switch_requested;          // Flag indicating switch is requested
    int target_source_index;       // Target source for pending switch
    
    // Frame feeding for virtual input approach
    AVFrame *current_frame;        // Current frame to feed to output
    pthread_mutex_t frame_mutex;   // Protect current_frame access
    int frame_ready;               // Flag indicating frame is ready
    pthread_cond_t frame_cond;     // Signal when new frame is ready
    int metrics_enable;
    
    // Additional fields for option parsing
    char *sources_str;
    char *ingest_mode_str;
    char *mode_str;
    char *on_cut_str;
    char *config_file;
    
    // Threading and synchronization
    pthread_mutex_t state_mutex;
    pthread_cond_t switch_cond;
    pthread_t health_thread;
    int health_running;
    pthread_t proxy_thread;        // UDP proxy thread (Phase 2)
    int proxy_running;             // Flag indicating proxy thread is active
    
    // Metrics and logging
    FILE *metrics_file;
    int json_metrics;
} MSwitchContext;

// Public API
int mswitch_init(MSwitchContext *msw, OptionsContext *o);
int mswitch_cleanup(MSwitchContext *msw);
int mswitch_start(MSwitchContext *msw);
int mswitch_stop(MSwitchContext *msw);

// Control interface
int mswitch_switch_to(MSwitchContext *msw, const char *source_id);
int mswitch_set_mode(MSwitchContext *msw, MSwitchMode mode);
int mswitch_set_auto(MSwitchContext *msw, int enable);
int mswitch_set_revert(MSwitchContext *msw, MSwitchRevert policy);

// Health monitoring
int mswitch_check_health(MSwitchContext *msw, int source_index);
int mswitch_update_health_metrics(MSwitchContext *msw, int source_index);

// Webhook API
int mswitch_webhook_start(MSwitchContext *msw);
int mswitch_webhook_stop(MSwitchContext *msw);
int mswitch_webhook_handle_request(MSwitchContext *msw, const char *json_request, char **json_response);

// CLI interface
int mswitch_cli_start(MSwitchContext *msw);
int mswitch_cli_stop(MSwitchContext *msw);
int mswitch_cli_handle_command(MSwitchContext *msw, const char *command);

// Utility functions
const char *mswitch_mode_to_string(MSwitchMode mode);
const char *mswitch_ingest_to_string(MSwitchIngest ingest);
MSwitchMode mswitch_string_to_mode(const char *str);
MSwitchIngest mswitch_string_to_ingest(const char *str);

// Health monitoring thread
void *mswitch_health_monitor(void *arg);

// Health detection
int mswitch_detect_black_frame(AVFrame *frame);
int mswitch_detect_stream_loss(MSwitchSource *source, int64_t current_time);
int mswitch_detect_pid_loss(MSwitchSource *source);
int mswitch_detect_cc_errors(MSwitchSource *source);
int mswitch_detect_cc_errors_per_sec(MSwitchSource *source, int64_t current_time);
int mswitch_detect_packet_loss_percent(MSwitchSource *source, int64_t current_time);

// Switching logic
int mswitch_switch_seamless(MSwitchContext *msw, int target_index);
int mswitch_switch_graceful(MSwitchContext *msw, int target_index);
int mswitch_switch_cutover(MSwitchContext *msw, int target_index);

// Filter-based switching
int mswitch_setup_filter(MSwitchContext *msw, void *filter_graph, void *streamselect_ctx);

// Freeze/Black frame generation
int mswitch_generate_freeze_frame(MSwitchContext *msw, AVFrame *last_frame, int duration_ms);
int mswitch_generate_black_frame(MSwitchContext *msw, int duration_ms);

#endif /* FFTOOLS_FFMPEG_MSWITCH_H */
