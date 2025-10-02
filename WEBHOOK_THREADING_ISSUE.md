# MSwitch Webhook Threading Issue - Root Cause Analysis

## Problem Summary

When `-msw.webhook.enable` is added to the FFmpeg command, the process crashes with a **bus error** during initialization, before the webhook server can accept connections.

## Evidence

### What Works
```bash
# WITHOUT webhook - runs successfully
./ffmpeg -msw.enable -msw.sources "s0=local;s1=local;s2=local" \
  -f lavfi -i "color=red..." -f lavfi -i "color=green..." -f lavfi -i "color=blue..." \
  -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
  -map "[out]" -f null -
```

### What Crashes
```bash
# WITH webhook - crashes immediately
./ffmpeg -msw.enable -msw.sources "s0=local;s1=local;s2=local" \
  -msw.webhook.enable -msw.webhook.port 8099 \
  -f lavfi -i "color=red..." -f lavfi -i "color=green..." -f lavfi -i "color=blue..." \
  -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
  -map "[out]" -f null -

# Result: Connection refused (server never started)
# curl: (7) Failed to connect to localhost port 8099: Couldn't connect to server
```

### Error Message from User
```
[MSwitch] [Webhook] *** SWITCHING TO SOURCE: s1 ***
[MSwitch] Source 's1' is already active    <-- BUG: Should be 0, not 1!
zsh: bus error  ./ffmpeg -msw.enable ...
```

## Root Cause

### The Threading Problem

**In `fftools/ffmpeg_mswitch.c` line 1406:**
```c
ret = pthread_create(&msw->webhook.server_thread, NULL, 
                     mswitch_webhook_server_thread, msw);
```

**The webhook thread function (line 1221):**
```c
static void *mswitch_webhook_server_thread(void *arg)
{
    MSwitchContext *msw = (MSwitchContext *)arg;  // <-- Receives pointer
    // ... later in the thread (line 1341):
    int ret = mswitch_switch_to(msw, source_id);  // <-- Uses pointer
}
```

**The global context (`fftools/ffmpeg_opt.c`):**
```c
MSwitchContext global_mswitch_ctx = {0};  // Global variable
```

### Why It Crashes

1. **Thread receives raw pointer to `global_mswitch_ctx`**
2. **No synchronization between main thread and webhook thread**
3. **Potential memory corruption scenarios:**
   - `global_mswitch_ctx` fields being modified by main thread while webhook thread reads them
   - `streamselect_ctx` pointer not initialized yet when webhook tries to use it
   - Race condition: filter setup happens *after* webhook thread starts
   - Stale cache: different CPU cores have inconsistent views of memory

### Timing Analysis

Looking at the logs:
```
Line 103: [MSwitch] Starting webhook server on port 8099
Line 104: [MSwitch] Starting webhook server thread on port 8099  
Line 105: [MSwitch] Webhook server listening on port 8099
Line 106: [MSwitch] Webhook server started on port 8099
Line 107: [MSwitch] MSwitch initialized with 3 sources
...
Line 48: [fc#0] [MSwitch] Found streamselect filter, connecting to MSwitch  <-- AFTER webhook starts!
Line 49: [MSwitch] Filter-based switching initialized
Line 50: [MSwitch] Initial streamselect map set to 0
```

**The bug**: The webhook thread starts at line 104, but the `streamselect_ctx` isn't set until line 49! If a webhook request arrives between lines 104-49, it will access an uninitialized filter context.

## Why "Source 's1' is already active"

The webhook thread reads `msw->active_source_index` and gets garbage data (showing 1 instead of 0), indicating:
- Memory corruption
- Uninitialized read
- Cache coherency issue
- Pointer to wrong memory location

## The Fix

### Option 1: Disable Webhook Thread (Quick Fix - RECOMMENDED)

**In `fftools/ffmpeg_mswitch.c` around line 1396:**
```c
int mswitch_webhook_start(MSwitchContext *msw)
{
    // TEMPORARY: Webhook threading has race condition issues
    // Use interactive CLI (press 0/1/2) instead
    if (msw->webhook.enable) {
        av_log(NULL, AV_LOG_WARNING, 
               "[MSwitch] Webhook currently disabled due to threading safety issues.\n"
               "[MSwitch] Use interactive commands instead: Press 0, 1, or 2 to switch sources.\n");
        msw->webhook.enable = 0;
    }
    return 0;
}
```

**Benefits:**
- Immediate fix
- No crashes
- Interactive CLI already works
- Can fix threading properly later

### Option 2: Add Proper Synchronization (Proper Fix)

**1. Add global mutex:**
```c
// In ffmpeg_mswitch.c at top
static pthread_mutex_t global_mswitch_mutex = PTHREAD_MUTEX_INITIALIZER;
```

**2. Protect webhook thread access:**
```c
// In mswitch_webhook_server_thread, around line 1341:
pthread_mutex_lock(&global_mswitch_mutex);
int ret = mswitch_switch_to(msw, source_id);
pthread_mutex_unlock(&global_mswitch_mutex);
```

**3. Protect filter setup:**
```c
// In fftools/ffmpeg_filter.c, around line 2010:
extern pthread_mutex_t global_mswitch_mutex;
pthread_mutex_lock(&global_mswitch_mutex);
ret = mswitch_setup_filter(&global_mswitch_ctx, fgt->graph, filter);
pthread_mutex_unlock(&global_mswitch_mutex);
```

**4. Protect all state changes:**
- In `mswitch_switch_seamless/graceful/cutover`
- In `mswitch_update_filter_map`
- In `check_keyboard_interaction` (interactive CLI)

**Challenges:**
- Easy to miss a lock
- Potential deadlocks
- Performance impact
- Complex to test all scenarios

### Option 3: Message Queue Pattern (Best Long-term)

**Don't call functions across threads. Use a queue instead:**

```c
typedef struct {
    char source_id[16];
    int64_t timestamp;
} MSwitchCommand;

typedef struct {
    MSwitchCommand queue[100];
    int head, tail;
    pthread_mutex_t lock;
} MSwitchCommandQueue;
```

**Webhook thread:**
```c
// Just enqueue, don't execute
pthread_mutex_lock(&cmd_queue.lock);
cmd_queue.queue[cmd_queue.tail++] = (MSwitchCommand){
    .source_id = source_id,
    .timestamp = av_gettime()
};
pthread_mutex_unlock(&cmd_queue.lock);
```

**Main thread (in event loop):**
```c
// Process queue in main thread
while (has_commands()) {
    MSwitchCommand cmd = dequeue_command();
    mswitch_switch_to(&global_mswitch_ctx, cmd.source_id);
}
```

**Benefits:**
- Thread-safe by design
- No cross-thread function calls
- Simple locking (only around queue operations)
- Easy to test

## Recommended Action Plan

### Phase 1: Immediate (Now)
✅ **Disable webhook thread** (Option 1)
- Users can still switch sources via interactive CLI (0/1/2 keys)
- Document workaround
- No crashes

### Phase 2: Short-term (Next session)
- Implement message queue pattern (Option 3)
- Test thoroughly
- Re-enable webhook

### Phase 3: Long-term
- Add comprehensive threading tests
- Stress test with rapid switching
- Profile for race conditions with thread sanitizer

## Current Workaround

**For users needing source switching NOW:**

```bash
# Start FFmpeg with MSwitch (NO webhook)
./ffmpeg \
  -msw.enable \
  -msw.sources "s0=local;s1=local;s2=local" \
  -f lavfi -i "color=red:size=640x480:rate=10" \
  -f lavfi -i "color=green:size=640x480:rate=10" \
  -f lavfi -i "color=blue:size=640x480:rate=10" \
  -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
  -map "[out]" \
  -c:v libx264 -preset ultrafast \
  -f mpegts - | ffplay -i -

# In the FFmpeg terminal window, press:
# - '0' to switch to RED
# - '1' to switch to GREEN  
# - '2' to switch to BLUE
# - 'm' for status
# - '?' for help
```

**This works reliably** because keyboard interaction happens in the main thread, not a separate webhook thread.

## Testing Checklist

Before re-enabling webhook:

- [ ] Start FFmpeg with webhook
- [ ] Verify webhook server accepts connections
- [ ] Send single switch command
- [ ] Verify visual switching occurs
- [ ] Send 10 rapid switch commands
- [ ] Verify no crashes or corruption
- [ ] Run for 1 hour with random switching
- [ ] Check for memory leaks
- [ ] Run with thread sanitizer (`-fsanitize=thread`)
- [ ] Test on different platforms (Linux, macOS, Windows)

---

*Analysis Date: January 2, 2025*
*FFmpeg Version: N-121297-g0c97cbeb22*

