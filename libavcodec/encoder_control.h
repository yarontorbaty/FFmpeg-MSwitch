/*
 * Runtime Encoder Control Interface
 * Allows external HTTP commands to control encoder parameters in real-time
 */

#ifndef AVCODEC_ENCODER_CONTROL_H
#define AVCODEC_ENCODER_CONTROL_H

#include <stdint.h>
#include <pthread.h>

#define ENCODER_CONTROL_MAX_ENCODERS 4

typedef struct EncoderControlCommand {
    int target_bitrate_kbps;     // Target bitrate in kbps
    int target_fps;              // Target framerate (0 = no change)
    int vbv_maxrate_kbps;        // VBV max bitrate
    int vbv_bufsize_kbps;        // VBV buffer size
    int force_idr;               // Force IDR frame
    int64_t timestamp;           // Command timestamp
    int valid;                   // Command is pending
} EncoderControlCommand;

typedef struct EncoderControlState {
    void *encoder_ctx;           // Pointer to encoder context (X264Context*)
    char encoder_name[64];       // Encoder identifier
    EncoderControlCommand pending_cmd;
    pthread_mutex_t mutex;
    int initialized;
} EncoderControlState;

typedef struct EncoderControlServer {
    int port;
    int server_fd;
    pthread_t server_thread;
    int running;
    EncoderControlState encoders[ENCODER_CONTROL_MAX_ENCODERS];
    int num_encoders;
    pthread_mutex_t global_mutex;
} EncoderControlServer;

// Global server instance
extern EncoderControlServer g_encoder_control_server;

// Initialize the control server
int encoder_control_init(int port);

// Register an encoder for control
int encoder_control_register(void *encoder_ctx, const char *encoder_name);

// Unregister an encoder
int encoder_control_unregister(void *encoder_ctx);

// Check for pending commands (called by encoder)
int encoder_control_get_command(void *encoder_ctx, EncoderControlCommand *cmd);

// Acknowledge command execution
int encoder_control_ack_command(void *encoder_ctx);

// Shutdown the control server
void encoder_control_shutdown(void);

// HTTP server thread
void *encoder_control_server_thread(void *arg);

#endif /* AVCODEC_ENCODER_CONTROL_H */

