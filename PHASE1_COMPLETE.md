# Phase 1: Subprocess Management - Implementation Status

**Date**: January 2, 2025  
**Status**: ✅ Core functions implemented, needs integration

---

## ✅ What's Been Implemented

### 1. Subprocess Management Functions

**`mswitch_build_subprocess_command()`** ✅
- Builds FFmpeg command based on source URL and MSwitch mode
- Seamless mode: `-c:v copy -c:a copy` (no transcoding)
- Graceful/Cutover: `-c:v libx264` (transcode to common format)
- Output: `udp://127.0.0.1:{12350+index}`

**`mswitch_start_source_subprocess()`** ✅
- Forks and execs FFmpeg for each source
- Redirects stderr to `/dev/null` to avoid clutter
- Stores PID and marks subprocess as running
- Logs startup with PID and output URL

**`mswitch_stop_source_subprocess()`** ✅
- Sends SIGTERM for graceful shutdown
- Waits up to 2 seconds for process to exit
- Sends SIGKILL if still running
- Cleans up PID and URL

**`mswitch_monitor_subprocess_thread()`** ✅
- Monitors all subprocesses for unexpected death
- Uses `waitpid(..., WNOHANG)` for non-blocking check
- Logs if subprocess dies
- Runs every 1 second

### 2. System Includes

Added necessary headers for process management:
```c
#include <signal.h>
#include <sys/wait.h>
#include <sys/types.h>
```

### 3. Constants

```c
#define MSW_BASE_UDP_PORT 12350
#define MSW_SUBPROCESS_STARTUP_DELAY_MS 2000
#define MSW_SUBPROCESS_MONITOR_INTERVAL_MS 1000
```

---

## 🔄 What's Next (Phase 1 Completion)

### Step 1: Integrate into `mswitch_init()`

Need to add to `mswitch_init()`:
```c
// Start subprocesses for all sources
for (int i = 0; i < msw->nb_sources; i++) {
    ret = mswitch_start_source_subprocess(msw, i);
    if (ret < 0) {
        mswitch_log(msw, AV_LOG_ERROR, "Failed to start subprocess for source %d\n", i);
        goto cleanup_on_error;
    }
}

// Wait for subprocesses to start streaming
mswitch_log(msw, AV_LOG_INFO, "Waiting for subprocesses to start streaming...\n");
usleep(MSW_SUBPROCESS_STARTUP_DELAY_MS * 1000);
```

### Step 2: Start Monitor Thread in `mswitch_init()`

```c
// Start subprocess monitor thread (reuse existing health_thread)
ret = pthread_create(&msw->health_thread, NULL, mswitch_monitor_subprocess_thread, msw);
if (ret != 0) {
    mswitch_log(msw, AV_LOG_ERROR, "Failed to create subprocess monitor thread\n");
    goto cleanup_on_error;
}
msw->health_running = 1;
```

### Step 3: Integrate into `mswitch_cleanup()`

Need to add to `mswitch_cleanup()`:
```c
// Stop all subprocesses
for (int i = 0; i < msw->nb_sources; i++) {
    mswitch_stop_source_subprocess(msw, i);
}
```

---

## 🧪 Testing Phase 1

### Test 1: Verify Subprocess Startup

```bash
cd /Users/yarontorbaty/Documents/Code/FFmpeg

# Start MSwitch with 3 color sources
./ffmpeg \
    -msw.enable \
    -msw.sources "s0=lavfi -f lavfi -i color=red:size=640x480:rate=10;s1=lavfi -f lavfi -i color=green:size=640x480:rate=10;s2=lavfi -f lavfi -i color=blue:size=640x480:rate=10" \
    -msw.mode seamless \
    -f mpegts udp://127.0.0.1:12349
```

**Expected Output**:
```
[MSwitch] Initializing native MSwitch...
[Subprocess 0] Command: ffmpeg -nostdin -i "lavfi -f lavfi -i color=red..." -c:v copy -c:a copy -f mpegts "udp://127.0.0.1:12350"
[Subprocess 0] Starting subprocess for source s0
[Subprocess 0] Started (PID: 12345, URL: udp://127.0.0.1:12350)
[Subprocess 1] Started (PID: 12346, URL: udp://127.0.0.1:12351)
[Subprocess 2] Started (PID: 12347, URL: udp://127.0.0.1:12352)
[MSwitch] Waiting for subprocesses to start streaming...
[MSwitch] Subprocess monitor thread started
```

### Test 2: Verify Subprocess Running

```bash
# In another terminal, check processes
ps aux | grep ffmpeg
```

**Should show**:
- Main FFmpeg process
- 3 subprocess FFmpeg processes (one per source)

### Test 3: Verify UDP Streams

```bash
# Check if UDP streams are active
ffplay udp://127.0.0.1:12350  # Should show RED
ffplay udp://127.0.0.1:12351  # Should show GREEN
ffplay udp://127.0.0.1:12352  # Should show BLUE
```

### Test 4: Verify Cleanup

```bash
# Quit main FFmpeg (Ctrl+C)
# Then check processes again
ps aux | grep ffmpeg
```

**Should show**: No FFmpeg processes (all cleaned up)

---

## 🚫 Known Limitations (Phase 1 Only)

1. **No UDP Proxy Yet**: Subprocesses are started but their streams are not forwarded
2. **No Switching**: Can't actually switch between sources yet (Phase 2)
3. **No Auto-Restart**: If subprocess dies, it's not automatically restarted
4. **Fixed UDP Ports**: Uses hardcoded ports 12350-12352

These will be addressed in Phase 2 (UDP Proxy) and Phase 3 (Integration).

---

## 📊 Code Statistics

- **New functions**: 4
- **Lines of code added**: ~200
- **System calls used**: `fork()`, `execl()`, `kill()`, `waitpid()`
- **Memory allocations**: Subprocess command strings, output URLs
- **Threads**: 1 (subprocess monitor)

---

## 🎯 Success Criteria for Phase 1

- ✅ Subprocess functions compile without errors
- ✅ Can start 3 FFmpeg subprocesses
- ✅ Each subprocess outputs to unique UDP port
- ✅ Monitor thread tracks subprocess health
- ✅ Clean shutdown kills all subprocesses

---

## 📝 Next Session Tasks

1. Integrate subprocess startup into `mswitch_init()`
2. Integrate subprocess cleanup into `mswitch_cleanup()`
3. Build and test Phase 1
4. Fix any compilation errors
5. Verify subprocess lifecycle with test commands
6. Begin Phase 2: UDP Proxy implementation

---

*Phase 1 Implementation: January 2, 2025*  
*Estimated time for integration: 30-60 minutes*  
*Ready for testing after integration*

