# Phase 2: UDP Proxy Implementation - STARTING NOW

**Start Time**: January 2, 2025  
**Estimated Duration**: 2-3 hours  
**Goal**: Forward UDP packets from active subprocess to main FFmpeg output

---

## 🎯 Objective

Implement a UDP proxy that:
1. Listens on all subprocess UDP ports (12350, 12351, 12352)
2. Forwards packets from the **active** source only
3. Discards packets from inactive sources
4. Handles source switching atomically

---

## 📋 Implementation Plan

### Step 1: UDP Socket Setup (~30 min)

**What to build**:
- Create UDP sockets for each source (3 sockets)
- Bind to localhost ports 12350, 12351, 12352
- Set non-blocking mode with `fcntl(O_NONBLOCK)`
- Create output mechanism (TBD: pipe to FFmpeg stdin or UDP output)

**Functions to add**:
```c
static int mswitch_create_udp_socket(int port)
static int mswitch_setup_udp_sockets(MSwitchContext *msw)
```

### Step 2: Packet Forwarding Thread (~60 min)

**What to build**:
- Main proxy loop using `select()` to monitor all source sockets
- Read packets from active source only
- Discard packets from inactive sources
- Write packets to output

**Function to add**:
```c
static void* mswitch_udp_proxy_thread(void *arg)
```

**Key logic**:
```c
while (msw->enable) {
    // Use select() to check all source sockets
    FD_ZERO(&read_fds);
    for (int i = 0; i < msw->nb_sources; i++) {
        FD_SET(source_sockets[i], &read_fds);
    }
    
    select(...);
    
    // Check which sockets have data
    for (int i = 0; i < msw->nb_sources; i++) {
        if (FD_ISSET(source_sockets[i], &read_fds)) {
            if (i == msw->active_source_index) {
                // Read and forward
                read(source_sockets[i], buffer, sizeof(buffer));
                write(output_fd, buffer, bytes_read);
            } else {
                // Read and discard
                read(source_sockets[i], buffer, sizeof(buffer));
            }
        }
    }
}
```

### Step 3: Integration with MSwitch (~30 min)

**What to modify**:
- Add `proxy_thread` to `MSwitchContext`
- Start proxy thread in `mswitch_init()` (after subprocesses start)
- Stop proxy thread in `mswitch_cleanup()`
- Add socket cleanup

### Step 4: Main FFmpeg Input Connection (~30 min)

**Challenge**: How to get proxy output into main FFmpeg?

**Options**:
1. **Pipe to stdin**: Proxy writes to pipe, FFmpeg reads from `pipe:0`
2. **UDP loopback**: Proxy forwards to another UDP port, FFmpeg reads from it
3. **Shared memory**: Complex, not recommended

**Recommended**: UDP loopback (option 2)
- Proxy listens on 12350, 12351, 12352
- Proxy forwards active source to 12400
- Main FFmpeg uses `-i udp://127.0.0.1:12400`

### Step 5: Testing (~30 min)

**Test command**:
```bash
./ffmpeg \
    -msw.enable \
    -msw.sources "s0=color=red;s1=color=green;s2=color=blue" \
    -msw.mode seamless \
    -i udp://127.0.0.1:12400 \
    -c:v libx264 -f mpegts - | ffplay -i -
```

**Expected behavior**:
- Starts showing RED (source 0)
- Press `1` → switches to GREEN
- Press `2` → switches to BLUE
- Press `0` → back to RED

---

## 🔧 Technical Details

### UDP Packet Size

```c
#define MSW_UDP_PACKET_SIZE 65536  // Max UDP packet size
```

### Socket Configuration

```c
// Create socket
int sock = socket(AF_INET, SOCK_DGRAM, 0);

// Set non-blocking
int flags = fcntl(sock, F_GETFL, 0);
fcntl(sock, F_SETFL, flags | O_NONBLOCK);

// Bind to port
struct sockaddr_in addr;
addr.sin_family = AF_INET;
addr.sin_addr.s_addr = inet_addr("127.0.0.1");
addr.sin_port = htons(port);
bind(sock, (struct sockaddr*)&addr, sizeof(addr));
```

### Select() Usage

```c
fd_set read_fds;
struct timeval tv = {.tv_sec = 0, .tv_usec = 100000}; // 100ms timeout

FD_ZERO(&read_fds);
for (int i = 0; i < 3; i++) {
    FD_SET(source_sockets[i], &read_fds);
}

int ready = select(max_fd + 1, &read_fds, NULL, NULL, &tv);
```

---

## 🎯 Success Criteria

- ✅ UDP sockets created and bound successfully
- ✅ Proxy thread starts without errors
- ✅ Packets forwarded from active source
- ✅ Packets discarded from inactive sources
- ✅ Visual switching works (RED → GREEN → BLUE)
- ✅ No packet loss or corruption
- ✅ Clean shutdown and cleanup

---

## 📊 Progress Tracking

- [ ] Step 1: UDP socket setup
- [ ] Step 2: Packet forwarding thread
- [ ] Step 3: MSwitch integration
- [ ] Step 4: Main FFmpeg input connection
- [ ] Step 5: Testing and verification

---

*Phase 2 Started: January 2, 2025*  
*Ready to code!*

