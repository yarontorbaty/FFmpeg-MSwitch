/*
 * Simple SRT Relay Server for MSwitch Direct
 * 
 * This relay accepts SRT connections from sources (publishers) and allows
 * multiple clients (like mswitchdirect) to connect and receive the stream.
 * 
 * Usage:
 *   ./srt_relay <listen_port> <output_port_1> [output_port_2] [output_port_3]
 * 
 * Example:
 *   ./srt_relay 9000 12350 12351 12352
 * 
 * Then:
 *   - Sources publish to: srt://127.0.0.1:9000
 *   - MSwitch connects to: srt://127.0.0.1:12350, srt://127.0.0.1:12351, etc.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>
#include <srt/srt.h>

#define MAX_CLIENTS 10
#define BUFFER_SIZE 2048

typedef struct {
    SRTSOCKET socket;
    int active;
    pthread_mutex_t mutex;
} Client;

typedef struct {
    int listen_port;
    int num_outputs;
    int output_ports[10];
    SRTSOCKET input_socket;
    Client clients[MAX_CLIENTS];
    int running;
    pthread_t input_thread;
    pthread_t output_threads[10];
} RelayServer;

RelayServer server;

void signal_handler(int sig) {
    printf("\nShutting down...\n");
    server.running = 0;
}

void* input_listener(void* arg) {
    SRTSOCKET listen_sock = srt_create_socket();
    struct sockaddr_in addr;
    
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(server.listen_port);
    
    if (srt_bind(listen_sock, (struct sockaddr*)&addr, sizeof(addr)) == SRT_ERROR) {
        fprintf(stderr, "Error: srt_bind failed: %s\n", srt_getlasterror_str());
        return NULL;
    }
    
    if (srt_listen(listen_sock, 5) == SRT_ERROR) {
        fprintf(stderr, "Error: srt_listen failed: %s\n", srt_getlasterror_str());
        return NULL;
    }
    
    printf("Listening for source on port %d...\n", server.listen_port);
    
    while (server.running) {
        struct sockaddr_in client_addr;
        int addr_len = sizeof(client_addr);
        
        SRTSOCKET client_sock = srt_accept(listen_sock, (struct sockaddr*)&client_addr, &addr_len);
        if (client_sock == SRT_INVALID_SOCK) {
            if (server.running)
                fprintf(stderr, "Warning: srt_accept failed: %s\n", srt_getlasterror_str());
            continue;
        }
        
        printf("Source connected!\n");
        server.input_socket = client_sock;
        
        // Read and relay data
        char buffer[BUFFER_SIZE];
        while (server.running) {
            int bytes = srt_recv(client_sock, buffer, BUFFER_SIZE);
            if (bytes <= 0) {
                if (bytes < 0)
                    fprintf(stderr, "Error reading from source: %s\n", srt_getlasterror_str());
                break;
            }
            
            // Broadcast to all active clients
            for (int i = 0; i < MAX_CLIENTS; i++) {
                pthread_mutex_lock(&server.clients[i].mutex);
                if (server.clients[i].active) {
                    int sent = srt_send(server.clients[i].socket, buffer, bytes);
                    if (sent < 0) {
                        fprintf(stderr, "Error sending to client %d: %s\n", i, srt_getlasterror_str());
                        server.clients[i].active = 0;
                        srt_close(server.clients[i].socket);
                    }
                }
                pthread_mutex_unlock(&server.clients[i].mutex);
            }
        }
        
        printf("Source disconnected\n");
        srt_close(client_sock);
        server.input_socket = SRT_INVALID_SOCK;
    }
    
    srt_close(listen_sock);
    return NULL;
}

void* output_listener(void* arg) {
    int port = *(int*)arg;
    SRTSOCKET listen_sock = srt_create_socket();
    struct sockaddr_in addr;
    
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    
    if (srt_bind(listen_sock, (struct sockaddr*)&addr, sizeof(addr)) == SRT_ERROR) {
        fprintf(stderr, "Error: srt_bind failed on port %d: %s\n", port, srt_getlasterror_str());
        return NULL;
    }
    
    if (srt_listen(listen_sock, 5) == SRT_ERROR) {
        fprintf(stderr, "Error: srt_listen failed on port %d: %s\n", port, srt_getlasterror_str());
        return NULL;
    }
    
    printf("Listening for clients on port %d...\n", port);
    
    while (server.running) {
        struct sockaddr_in client_addr;
        int addr_len = sizeof(client_addr);
        
        SRTSOCKET client_sock = srt_accept(listen_sock, (struct sockaddr*)&client_addr, &addr_len);
        if (client_sock == SRT_INVALID_SOCK) {
            if (server.running)
                fprintf(stderr, "Warning: srt_accept failed on port %d: %s\n", port, srt_getlasterror_str());
            continue;
        }
        
        // Find free slot
        int slot = -1;
        for (int i = 0; i < MAX_CLIENTS; i++) {
            pthread_mutex_lock(&server.clients[i].mutex);
            if (!server.clients[i].active) {
                server.clients[i].socket = client_sock;
                server.clients[i].active = 1;
                slot = i;
                pthread_mutex_unlock(&server.clients[i].mutex);
                break;
            }
            pthread_mutex_unlock(&server.clients[i].mutex);
        }
        
        if (slot >= 0) {
            printf("Client connected on port %d (slot %d)\n", port, slot);
        } else {
            fprintf(stderr, "No free slots for client on port %d\n", port);
            srt_close(client_sock);
        }
    }
    
    srt_close(listen_sock);
    return NULL;
}

int main(int argc, char* argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <input_port> <output_port_1> [output_port_2] ...\n", argv[0]);
        fprintf(stderr, "Example: %s 9000 12350 12351 12352\n", argv[0]);
        return 1;
    }
    
    // Initialize SRT
    if (srt_startup() < 0) {
        fprintf(stderr, "Error: srt_startup failed\n");
        return 1;
    }
    
    // Parse arguments
    server.listen_port = atoi(argv[1]);
    server.num_outputs = argc - 2;
    if (server.num_outputs > 10) {
        fprintf(stderr, "Error: Maximum 10 output ports\n");
        return 1;
    }
    
    for (int i = 0; i < server.num_outputs; i++) {
        server.output_ports[i] = atoi(argv[i + 2]);
    }
    
    // Initialize clients
    for (int i = 0; i < MAX_CLIENTS; i++) {
        server.clients[i].active = 0;
        pthread_mutex_init(&server.clients[i].mutex, NULL);
    }
    
    server.running = 1;
    server.input_socket = SRT_INVALID_SOCK;
    
    // Setup signal handler
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    printf("SRT Relay Server\n");
    printf("================\n");
    printf("Input port: %d\n", server.listen_port);
    printf("Output ports: ");
    for (int i = 0; i < server.num_outputs; i++) {
        printf("%d ", server.output_ports[i]);
    }
    printf("\n\n");
    
    // Start input listener
    pthread_create(&server.input_thread, NULL, input_listener, NULL);
    
    // Start output listeners
    for (int i = 0; i < server.num_outputs; i++) {
        pthread_create(&server.output_threads[i], NULL, output_listener, &server.output_ports[i]);
    }
    
    // Wait for threads
    pthread_join(server.input_thread, NULL);
    for (int i = 0; i < server.num_outputs; i++) {
        pthread_join(server.output_threads[i], NULL);
    }
    
    // Cleanup
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (server.clients[i].active) {
            srt_close(server.clients[i].socket);
        }
        pthread_mutex_destroy(&server.clients[i].mutex);
    }
    
    srt_cleanup();
    printf("Shutdown complete\n");
    
    return 0;
}
