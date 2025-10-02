# Phase 2B: Standalone MSwitch Proxy

**Start Time**: January 2, 2025  
**Estimated Duration**: 4-6 hours  
**Goal**: Extract UDP proxy to standalone binary with HTTP control

---

## 🎯 Objective

Create `mswitch_proxy` - a standalone binary that:
1. Starts **before** any FFmpeg instance
2. Listens on subprocess UDP ports (12350, 12351, 12352)
3. Forwards packets from active source to output (12400)
4. Accepts HTTP commands to switch sources
5. Provides status and health endpoints

---

## 📋 Implementation Plan

### Step 1: Create Standalone Proxy Binary (2 hours)

**New File**: `tools/mswitch_proxy.c`

**What to Extract**:
- UDP socket creation (`mswitch_create_udp_socket`)
- UDP proxy thread (`mswitch_udp_proxy_thread`)
- Remove FFmpeg dependencies (use plain C)

**Add**:
- `main()` function with argument parsing
- Signal handlers for clean shutdown
- Configuration structure

**Compilation**:
```bash
gcc -o mswitch_proxy tools/mswitch_proxy.c -lpthread
```

### Step 2: Add HTTP Control Interface (2 hours)

**Endpoints to Implement**:
```
POST /switch     - Switch to source
GET  /status     - Current status
GET  /health     - Health check
POST /shutdown   - Graceful shutdown
```

**Example Usage**:
```bash
# Switch to source 1
curl -X POST http://localhost:8099/switch -d '{"source":1}'

# Get status
curl http://localhost:8099/status

# Response:
{
  "active_source": 1,
  "sources": [
    {"id": 0, "port": 12350, "packets": 1234},
    {"id": 1, "port": 12351, "packets": 5678, "active": true},
    {"id": 2, "port": 12352, "packets": 910}
  ]
}
```

### Step 3: Create Demo Script (1 hour)

**New File**: `tests/mswitch_standalone_demo.sh`

**Flow**:
```bash
#!/bin/bash

# Step 1: Start standalone proxy
./mswitch_proxy --sources 3 --output 12400 --control 8099 &
PROXY_PID=$!

# Step 2: Start 3 source FFmpeg processes
ffmpeg -f lavfi -i color=red:size=320x240:rate=10 \
       -c:v libx264 -f mpegts udp://127.0.0.1:12350 &

ffmpeg -f lavfi -i color=green:size=320x240:rate=10 \
       -c:v libx264 -f mpegts udp://127.0.0.1:12351 &

ffmpeg -f lavfi -i color=blue:size=320x240:rate=10 \
       -c:v libx264 -f mpegts udp://127.0.0.1:12352 &

# Step 3: Start output FFmpeg with ffplay
ffmpeg -i udp://127.0.0.1:12400 \
       -c:v libx264 -f mpegts - | ffplay -i - &

# Step 4: Interactive switching
echo "Press 0, 1, 2 to switch sources, q to quit"
while true; do
    read -n 1 key
    case $key in
        0) curl -s -X POST http://localhost:8099/switch -d '{"source":0}' ;;
        1) curl -s -X POST http://localhost:8099/switch -d '{"source":1}' ;;
        2) curl -s -X POST http://localhost:8099/switch -d '{"source":2}' ;;
        q) break ;;
    esac
done

# Cleanup
kill $PROXY_PID
killall ffmpeg ffplay
```

### Step 4: Testing & Verification (1 hour)

**Test Cases**:
1. ✅ Proxy starts without errors
2. ✅ Binds to correct ports
3. ✅ Forwards packets from source 0 (initial)
4. ✅ HTTP switch command works
5. ✅ Visual output changes (RED → GREEN → BLUE)
6. ✅ Status endpoint returns correct info
7. ✅ Clean shutdown

---

## 🔧 Technical Details

### Standalone Proxy Architecture

```c
// Main structure
typedef struct {
    int num_sources;
    int output_port;
    int control_port;
    int active_source;
    int source_sockets[MAX_SOURCES];
    int output_socket;
    int control_socket;
    pthread_t proxy_thread;
    pthread_t control_thread;
    pthread_mutex_t mutex;
    int running;
} MSwitchProxyContext;
```

### HTTP Control Server (Simplified)

```c
void* control_thread(void *arg) {
    MSwitchProxyContext *ctx = arg;
    
    // Listen on control port
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    bind(server_fd, ...);
    listen(server_fd, 5);
    
    while (ctx->running) {
        int client_fd = accept(server_fd, ...);
        
        char request[4096];
        read(client_fd, request, sizeof(request));
        
        if (strstr(request, "POST /switch")) {
            // Parse JSON body
            int source = parse_source_from_json(request);
            
            pthread_mutex_lock(&ctx->mutex);
            ctx->active_source = source;
            pthread_mutex_unlock(&ctx->mutex);
            
            send_response(client_fd, "{\"status\":\"ok\"}");
        }
        else if (strstr(request, "GET /status")) {
            char response[1024];
            snprintf(response, sizeof(response),
                    "{\"active_source\":%d,\"num_sources\":%d}",
                    ctx->active_source, ctx->num_sources);
            send_response(client_fd, response);
        }
        
        close(client_fd);
    }
}
```

---

## 📊 File Structure

```
tools/
├── mswitch_proxy.c           (NEW - standalone proxy)
├── mswitch_proxy.h           (NEW - proxy structures)
└── Makefile                  (UPDATE - add mswitch_proxy target)

tests/
├── mswitch_standalone_demo.sh   (NEW - demo script)
└── test_standalone_proxy.sh     (NEW - automated test)

doc/
└── MSWITCH_PROXY.md            (NEW - user documentation)
```

---

## ✅ Success Criteria

- ✅ `mswitch_proxy` binary compiles
- ✅ Can start without FFmpeg
- ✅ Listens on correct UDP ports
- ✅ Forwards packets correctly
- ✅ HTTP control works
- ✅ **Visual switching works (RED → GREEN → BLUE)** 🎨
- ✅ Clean shutdown
- ✅ No memory leaks

---

## 🚀 Expected Outcome

**After Phase 2B, you'll be able to**:
```bash
# Terminal 1: Start proxy
$ ./mswitch_proxy --sources 3 --output 12400 --control 8099
[Proxy] Listening on ports 12350, 12351, 12352
[Proxy] Forwarding to port 12400
[Proxy] Control server on port 8099
[Proxy] Active source: 0 (RED)

# Terminal 2: Start sources + viewer
$ ./tests/mswitch_standalone_demo.sh
Starting sources...
Starting viewer...
[Viewer shows RED screen]

# Terminal 3: Switch sources
$ curl -X POST http://localhost:8099/switch -d '{"source":1}'
[Viewer switches to GREEN] ✅

$ curl -X POST http://localhost:8099/switch -d '{"source":2}'
[Viewer switches to BLUE] ✅
```

**THIS IS THE GOAL!** 🎯

---

*Phase 2B Start: January 2, 2025*  
*Ready to code!*

