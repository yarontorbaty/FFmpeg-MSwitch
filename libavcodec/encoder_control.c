/*
 * Runtime Encoder Control Interface Implementation
 */

#include "encoder_control.h"
#include "libavutil/log.h"
#include "libavutil/time.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

// Global server instance
EncoderControlServer g_encoder_control_server = {0};

int encoder_control_init(int port) {
    if (g_encoder_control_server.running) {
        av_log(NULL, AV_LOG_WARNING, "[Encoder Control] Server already running\n");
        return 0;
    }

    pthread_mutex_init(&g_encoder_control_server.global_mutex, NULL);
    g_encoder_control_server.port = port;
    g_encoder_control_server.num_encoders = 0;

    // Create socket
    g_encoder_control_server.server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (g_encoder_control_server.server_fd < 0) {
        av_log(NULL, AV_LOG_ERROR, "[Encoder Control] Failed to create socket\n");
        return -1;
    }

    // Set socket options
    int opt = 1;
    setsockopt(g_encoder_control_server.server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    // Bind socket
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);

    if (bind(g_encoder_control_server.server_fd, (struct sockaddr*)&address, sizeof(address)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "[Encoder Control] Failed to bind to port %d\n", port);
        close(g_encoder_control_server.server_fd);
        return -1;
    }

    // Listen
    if (listen(g_encoder_control_server.server_fd, 3) < 0) {
        av_log(NULL, AV_LOG_ERROR, "[Encoder Control] Failed to listen\n");
        close(g_encoder_control_server.server_fd);
        return -1;
    }

    // Start server thread
    g_encoder_control_server.running = 1;
    pthread_create(&g_encoder_control_server.server_thread, NULL, encoder_control_server_thread, NULL);

    av_log(NULL, AV_LOG_INFO, "[Encoder Control] HTTP server started on port %d\n", port);
    return 0;
}

int encoder_control_register(void *encoder_ctx, const char *encoder_name) {
    pthread_mutex_lock(&g_encoder_control_server.global_mutex);

    if (g_encoder_control_server.num_encoders >= ENCODER_CONTROL_MAX_ENCODERS) {
        pthread_mutex_unlock(&g_encoder_control_server.global_mutex);
        av_log(NULL, AV_LOG_ERROR, "[Encoder Control] Max encoders reached\n");
        return -1;
    }

    int idx = g_encoder_control_server.num_encoders++;
    EncoderControlState *state = &g_encoder_control_server.encoders[idx];

    state->encoder_ctx = encoder_ctx;
    snprintf(state->encoder_name, sizeof(state->encoder_name), "%s", encoder_name);
    memset(&state->pending_cmd, 0, sizeof(state->pending_cmd));
    pthread_mutex_init(&state->mutex, NULL);
    state->initialized = 1;

    pthread_mutex_unlock(&g_encoder_control_server.global_mutex);

    av_log(NULL, AV_LOG_INFO, "[Encoder Control] Registered encoder '%s' (index %d)\n", encoder_name, idx);
    return idx;
}

int encoder_control_unregister(void *encoder_ctx) {
    pthread_mutex_lock(&g_encoder_control_server.global_mutex);

    for (int i = 0; i < g_encoder_control_server.num_encoders; i++) {
        if (g_encoder_control_server.encoders[i].encoder_ctx == encoder_ctx) {
            g_encoder_control_server.encoders[i].initialized = 0;
            pthread_mutex_destroy(&g_encoder_control_server.encoders[i].mutex);
            av_log(NULL, AV_LOG_INFO, "[Encoder Control] Unregistered encoder '%s'\n",
                   g_encoder_control_server.encoders[i].encoder_name);
            break;
        }
    }

    pthread_mutex_unlock(&g_encoder_control_server.global_mutex);
    return 0;
}

int encoder_control_get_command(void *encoder_ctx, EncoderControlCommand *cmd) {
    for (int i = 0; i < g_encoder_control_server.num_encoders; i++) {
        EncoderControlState *state = &g_encoder_control_server.encoders[i];
        if (state->encoder_ctx == encoder_ctx && state->initialized) {
            pthread_mutex_lock(&state->mutex);
            if (state->pending_cmd.valid) {
                memcpy(cmd, &state->pending_cmd, sizeof(EncoderControlCommand));
                pthread_mutex_unlock(&state->mutex);
                return 1; // Command available
            }
            pthread_mutex_unlock(&state->mutex);
            return 0; // No command
        }
    }
    return -1; // Encoder not found
}

int encoder_control_ack_command(void *encoder_ctx) {
    for (int i = 0; i < g_encoder_control_server.num_encoders; i++) {
        EncoderControlState *state = &g_encoder_control_server.encoders[i];
        if (state->encoder_ctx == encoder_ctx && state->initialized) {
            pthread_mutex_lock(&state->mutex);
            state->pending_cmd.valid = 0;
            pthread_mutex_unlock(&state->mutex);
            return 0;
        }
    }
    return -1;
}

void encoder_control_shutdown(void) {
    if (!g_encoder_control_server.running) return;

    g_encoder_control_server.running = 0;
    close(g_encoder_control_server.server_fd);
    pthread_join(g_encoder_control_server.server_thread, NULL);

    for (int i = 0; i < g_encoder_control_server.num_encoders; i++) {
        if (g_encoder_control_server.encoders[i].initialized) {
            pthread_mutex_destroy(&g_encoder_control_server.encoders[i].mutex);
        }
    }

    pthread_mutex_destroy(&g_encoder_control_server.global_mutex);
    av_log(NULL, AV_LOG_INFO, "[Encoder Control] Server shut down\n");
}

// Parse simple JSON-like command: {"bitrate":5000,"fps":15,"force_idr":1}
static int parse_command(const char *json, EncoderControlCommand *cmd) {
    memset(cmd, 0, sizeof(*cmd));
    cmd->timestamp = av_gettime_relative();
    cmd->valid = 1;

    // Simple parsing (not robust, just for testing)
    const char *p = strstr(json, "\"bitrate\":");
    if (p) {
        sscanf(p + 10, "%d", &cmd->target_bitrate_kbps);
    }

    p = strstr(json, "\"fps\":");
    if (p) {
        sscanf(p + 6, "%d", &cmd->target_fps);
    }

    p = strstr(json, "\"vbv_maxrate\":");
    if (p) {
        sscanf(p + 14, "%d", &cmd->vbv_maxrate_kbps);
    }

    p = strstr(json, "\"vbv_bufsize\":");
    if (p) {
        sscanf(p + 14, "%d", &cmd->vbv_bufsize_kbps);
    }

    p = strstr(json, "\"force_idr\":");
    if (p) {
        sscanf(p + 12, "%d", &cmd->force_idr);
    }

    return 0;
}

void *encoder_control_server_thread(void *arg) {
    av_log(NULL, AV_LOG_INFO, "[Encoder Control] Server thread started\n");

    while (g_encoder_control_server.running) {
        struct sockaddr_in client_addr;
        socklen_t addr_len = sizeof(client_addr);
        int client_fd = accept(g_encoder_control_server.server_fd, (struct sockaddr*)&client_addr, &addr_len);

        if (client_fd < 0) {
            if (g_encoder_control_server.running) {
                av_log(NULL, AV_LOG_ERROR, "[Encoder Control] Accept failed\n");
            }
            break;
        }

        // Read HTTP request
        char buffer[4096] = {0};
        int bytes_read = read(client_fd, buffer, sizeof(buffer) - 1);

        if (bytes_read > 0) {
            // Find JSON body (after \r\n\r\n)
            char *body = strstr(buffer, "\r\n\r\n");
            if (body) {
                body += 4;

                // Parse command
                EncoderControlCommand cmd;
                if (parse_command(body, &cmd) == 0) {
                    // Apply to all registered encoders
                    for (int i = 0; i < g_encoder_control_server.num_encoders; i++) {
                        EncoderControlState *state = &g_encoder_control_server.encoders[i];
                        if (state->initialized) {
                            pthread_mutex_lock(&state->mutex);
                            memcpy(&state->pending_cmd, &cmd, sizeof(cmd));
                            pthread_mutex_unlock(&state->mutex);
                            av_log(NULL, AV_LOG_INFO, "[Encoder Control] Command queued for '%s': bitrate=%d kbps, fps=%d, force_idr=%d\n",
                                   state->encoder_name, cmd.target_bitrate_kbps, cmd.target_fps, cmd.force_idr);
                        }
                    }

                    // Send HTTP response
                    const char *response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"ok\"}\r\n";
                    write(client_fd, response, strlen(response));
                } else {
                    const char *response = "HTTP/1.1 400 Bad Request\r\n\r\n";
                    write(client_fd, response, strlen(response));
                }
            } else {
                const char *response = "HTTP/1.1 400 Bad Request\r\n\r\n";
                write(client_fd, response, strlen(response));
            }
        }

        close(client_fd);
    }

    av_log(NULL, AV_LOG_INFO, "[Encoder Control] Server thread stopped\n");
    return NULL;
}

