# MSwitch Filter-Based Switching - Current Status

## ✅ What's Working

1. **Filter Detection & Integration**: The system successfully detects `streamselect` filters in filter graphs and connects them to MSwitch.

2. **Basic Functionality Without Webhook**: 
   - MSwitch initializes properly
   - Stream selection filter is detected and connected
   - Filter map can be updated programmatically

**Working Test Command**:
```bash
./ffmpeg \
  -msw.enable \
  -msw.sources "s0=local;s1=local;s2=local" \
  -f lavfi -i "color=red:size=320x240:rate=5" \
  -f lavfi -i "color=green:size=320x240:rate=5" \
  -f lavfi -i "color=blue:size=320x240:rate=5" \
  -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
  -map "[out]" \
  -t 5 -f null -
```

## ❌ Current Issue: Bus Error with Webhook Enabled

### Problem
When `-msw.webhook.enable -msw.webhook.port 8099` is added, FFmpeg crashes with a bus error before the webhook server can fully initialize.

### Symptoms
1. **No webhook server listening**: Connection refused when trying to connect
2. **Bus error**: Memory access violation
3. **Inconsistent state**: Error log shows "Source 's1' is already active" when trying to switch to s1 for the first time, suggesting `active_source_index` is being corrupted

### Error Message from User
```
[MSwitch] [Webhook] *** SWITCHING TO SOURCE: s1 ***
[MSwitch] Source 's1' is already active
[MSwitch] [Webhook] Switch result: 0
zsh: bus error  ./ffmpeg -msw.enable -msw.sources "s0=local;s1=local;s2=local" ...
```

### Analysis

#### Likely Root Causes

**1. Memory Corruption**
- The bus error indicates improper memory access
- `active_source_index` showing wrong value (1 instead of 0) suggests memory corruption
- Possible causes:
  - Buffer overflow in webhook request parsing
  - Race condition between webhook thread and main thread
  - Uninitialized or dangling pointer in `MSwitchContext`

**2. Threading Issues**
- Webhook runs in a separate thread: `mswitch_webhook_server_thread`
- This thread accesses `MSwitchContext` which is also accessed by main thread
- No mutex protection around `global_mswitch_ctx` access from webhook thread

**3. Context Lifecycle**
- The webhook thread is created and detached during `mswitch_init`
- It receives a pointer to `MSwitchContext` which might be on the stack or in an unstable location
- If MSwitch context moves or is reallocated, webhook thread has stale pointer

### Specific Problem Areas

#### In `fftools/ffmpeg_mswitch.c` line 1338-1341:
```c
// Webhook thread accessing MSwitchContext
MSwitchContext *msw = (MSwitchContext *)arg;  // From thread creation
...
int ret = mswitch_switch_to(msw, source_id);
```

This could crash if:
1. `msw` pointer is invalid
2. `msw` fields are corrupted
3. Filter context (`msw->streamselect_ctx`) is not fully initialized yet

#### In `fftools/ffmpeg_mswitch.c` line 972-980:
```c
int mswitch_switch_seamless(MSwitchContext *msw, int target_index)
{
    pthread_mutex_lock(&msw->state_mutex);
    // ... update filter and state
    pthread_mutex_unlock(&msw->state_mutex);
}
```

The webhook thread calls this, but there's no guarantee the mutex is initialized or that `msw` is valid.

## 🔍 Debugging Steps Attempted

1. ✅ Added null pointer checks in switching functions
2. ✅ Added logging before/after switch calls
3. ✅ Fixed extern variable declarations in `ffmpeg_filter.c`
4. ✅ Added filter pointer validation
5. ❌ Still crashes with webhook enabled

## 📋 Recommended Fixes

### Short-term (Quick Fix)
**Disable webhook thread until threading issues resolved:**
```c
// In mswitch_webhook_start():
if (msw->webhook.enable) {
    av_log(NULL, AV_LOG_WARNING, 
           "Webhook currently disabled due to threading issues. "
           "Use interactive CLI (press 0/1/2) instead.\n");
    return 0;
}
```

### Medium-term (Fix Threading)
1. **Add proper locking around global context**:
   ```c
   static pthread_mutex_t global_mswitch_mutex = PTHREAD_MUTEX_INITIALIZER;
   
   // In webhook thread:
   pthread_mutex_lock(&global_mswitch_mutex);
   int ret = mswitch_switch_to(&global_mswitch_ctx, source_id);
   pthread_mutex_unlock(&global_mswitch_mutex);
   ```

2. **Pass context more safely**:
   Instead of passing raw pointer, use a wrapper:
   ```c
   typedef struct {
       MSwitchContext *msw;
       int *shutdown_flag;
   } WebhookThreadContext;
   ```

3. **Validate context before use**:
   ```c
   // Add magic number to MSwitchContext
   #define MSWITCH_MAGIC 0x4D535754  // "MSWT"
   
   struct MSwitchContext {
       uint32_t magic;  // First field
       // ... rest of fields
   };
   
   // In webhook thread:
   if (msw->magic != MSWITCH_MAGIC) {
       av_log(NULL, AV_LOG_ERROR, "Invalid MSwitchContext!\n");
       return NULL;
   }
   ```

### Long-term (Architecture Redesign)
1. **Use message queue instead of direct function calls**:
   - Webhook thread puts commands in a queue
   - Main thread processes queue during event loop
   - No cross-thread function calls

2. **Use FFmpeg's existing command infrastructure**:
   - Integrate with `check_keyboard_interaction()` which already handles interactive commands safely
   - Webhook writes to a pipe that main thread reads

## 🧪 Testing Strategy

### Phase 1: Verify Without Webhook
- [x] Test filter detection
- [x] Test manual source switching via interactive CLI
- [ ] **Verify visual switching actually works via CLI (0/1/2 keys)**

### Phase 2: Fix Webhook (After Phase 1 succeeds)
- [ ] Add thread safety primitives
- [ ] Test webhook with single request
- [ ] Test multiple rapid requests
- [ ] Test long-running stability

### Phase 3: Production Testing
- [ ] Test with real UDP sources (not lavfi)
- [ ] Test different switch modes (seamless/graceful/cutover)
- [ ] Stress test with rapid switching

## 📝 Current Test Commands

### Working (No Webhook):
```bash
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

# Then press 0, 1, 2 to switch sources interactively
```

### Broken (With Webhook):
```bash
./ffmpeg \
  -msw.enable \
  -msw.sources "s0=local;s1=local;s2=local" \
  -msw.webhook.enable \
  -msw.webhook.port 8099 \
  -f lavfi -i "color=red:size=640x480:rate=10" \
  -f lavfi -i "color=green:size=640x480:rate=10" \
  -f lavfi -i "color=blue:size=640x480:rate=10" \
  -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
  -map "[out]" \
  -c:v libx264 -preset ultrafast \
  -f mpegts - | ffplay -i -

# Crashes before webhook server starts
```

## 🎯 Next Steps

1. **PRIORITY 1**: Test interactive CLI switching (without webhook)
   - Run the working command above
   - Press 0, 1, 2 keys to switch
   - Verify visual changes in ffplay

2. **PRIORITY 2**: If CLI switching works, document it as the current working solution

3. **PRIORITY 3**: Fix webhook threading issues using one of the recommended approaches

4. **PRIORITY 4**: Add comprehensive documentation and test scripts once webhook is stable

---

*Status as of: January 2, 2025*
*Last tested FFmpeg version: N-121297-g0c97cbeb22*

