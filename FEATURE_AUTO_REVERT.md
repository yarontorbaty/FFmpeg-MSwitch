# Auto-Revert to Preferred Source - Implementation Guide

**Issue**: #8  
**Branch**: `feature/auto-revert-preferred-source`  
**Status**: 🟡 In Progress

---

## 🎯 Goal

Add optional auto-revert functionality that automatically switches back to higher-priority sources when they become healthy again.

## 📋 Implementation Checklist

### Phase 1: Core Logic ✅ Ready to Implement

- [ ] **Add new context fields** (`libavformat/mswitchdirect.c`)
  ```c
  // Auto-revert configuration
  int auto_revert_enabled;           // Enable auto-revert to preferred source
  int revert_delay_ms;               // Delay before reverting (default: 5000ms)
  int revert_stability_time_ms;      // Source must be stable before revert (default: 3000ms)
  int64_t *source_healthy_since;     // Track when each source became healthy
  int64_t last_revert_time;          // Last revert time (for cooldown)
  int revert_cooldown_ms;            // Cooldown between reverts (default: 10000ms)
  ```

- [ ] **Add command-line options** (`mswitchdirect_options` array)
  ```c
  { "msw_auto_revert", "Enable auto-revert to preferred source", 
    OFFSET(auto_revert_enabled), AV_OPT_TYPE_BOOL, {.i64=0}, 0, 1, AV_OPT_FLAG_DECODING_PARAM },
  { "msw_revert_delay", "Delay before reverting to preferred source (ms)", 
    OFFSET(revert_delay_ms), AV_OPT_TYPE_INT, {.i64=5000}, 1000, 60000, AV_OPT_FLAG_DECODING_PARAM },
  { "msw_revert_stability_time", "Source must be stable before revert (ms)", 
    OFFSET(revert_stability_time_ms), AV_OPT_TYPE_INT, {.i64=3000}, 1000, 30000, AV_OPT_FLAG_DECODING_PARAM },
  ```

- [ ] **Initialize new fields** (`mswitchdirect_read_header`)
  ```c
  ctx->auto_revert_enabled = 0;  // Disabled by default (backward compatible)
  ctx->revert_delay_ms = 5000;
  ctx->revert_stability_time_ms = 3000;
  ctx->revert_cooldown_ms = 10000;
  ctx->last_revert_time = 0;
  ctx->source_healthy_since = av_mallocz(ctx->num_sources * sizeof(int64_t));
  ```

### Phase 2: Selection Logic 🔄 Priority-Based

- [ ] **Modify health monitor** (`health_monitor_thread`)
  - Track when each source becomes healthy
  - Update `source_healthy_since` timestamps
  - Check for revert conditions

- [ ] **Update best source selection** (both locations)
  - **Location 1**: `health_monitor_thread` (~line 764)
  - **Location 2**: `read_packet` auto-failover (~line 1365)
  
  ```c
  // Priority-based selection (lowest index = highest priority)
  int best_source = -1;
  for (int i = 0; i < ctx->num_sources; i++) {
      if (ctx->sources[i].is_healthy) {
          if (best_source < 0 || i < best_source) {
              best_source = i;  // Prefer lower index (higher priority)
          }
      }
  }
  ```

- [ ] **Add revert logic** (`read_packet`)
  ```c
  // Check for auto-revert opportunity
  if (ctx->auto_revert_enabled && best_source < active_source) {
      // Higher priority source is available
      int64_t current_time = av_gettime() / 1000;
      int64_t time_since_healthy = current_time - ctx->source_healthy_since[best_source];
      int64_t time_since_last_revert = current_time - ctx->last_revert_time;
      
      if (time_since_healthy >= ctx->revert_stability_time_ms &&
          time_since_last_revert >= ctx->revert_cooldown_ms) {
          // Perform auto-revert
          ctx->last_revert_time = current_time;
          // ... switch to best_source
      }
  }
  ```

### Phase 3: Anti-Thrashing Protection 🛡️

- [ ] **Track source recovery time**
  - Update `source_healthy_since` when source becomes healthy
  - Reset to 0 when source becomes unhealthy

- [ ] **Implement stability check**
  - Source must be healthy for `revert_stability_time_ms` before revert
  - Prevents revert to flapping sources

- [ ] **Add cooldown mechanism**
  - Track `last_revert_time`
  - Enforce `revert_cooldown_ms` between reverts
  - Prevents rapid switching

- [ ] **Add revert attempt counter**
  - Limit consecutive revert attempts
  - Disable auto-revert if source is unstable

### Phase 4: Logging & Debugging 📝

- [ ] **Add detailed logging**
  ```c
  av_log(NULL, AV_LOG_INFO, "[MSwitch Direct] Source %d recovered (healthy for %lldms)\n", 
         i, time_since_healthy);
  av_log(NULL, AV_LOG_WARNING, "[MSwitch Direct] ⏪ AUTO-REVERT: Switching from source %d to source %d (preferred source)\n",
         active_source, best_source);
  av_log(NULL, AV_LOG_DEBUG, "[MSwitch Direct] Auto-revert blocked: source not stable (%lld/%dms)\n",
         time_since_healthy, ctx->revert_stability_time_ms);
  ```

- [ ] **Add status to HTTP API**
  - Include auto-revert settings in status response
  - Show source health duration

### Phase 5: Testing 🧪

- [ ] **Create test script** (`test_auto_revert.sh`)
  - Start with Source 0 active
  - Kill Source 0 → verify failover to Source 1
  - Restart Source 0 → verify auto-revert after delay
  - Test stability requirement
  - Test cooldown period

- [ ] **Test edge cases**
  - Source flapping (rapid healthy/unhealthy)
  - All sources fail simultaneously
  - Revert during manual switch
  - Auto-revert disabled (default behavior)

- [ ] **Performance testing**
  - Verify no performance impact when disabled
  - Check memory usage with many sources

### Phase 6: Documentation 📚

- [ ] **Update README**
  - Add auto-revert section
  - Document new options
  - Add examples

- [ ] **Update RELEASE_NOTES.md**
  - Add feature description
  - Update examples

- [ ] **Add inline documentation**
  - Comment the revert logic
  - Explain priority system

---

## 🔧 Key Implementation Details

### Priority System
- **Implicit priority**: Source index determines priority (0 = highest)
- **User control**: Order sources by preference in `-msw_sources`
- **No explicit priority field**: Keeps API simple

### Selection Algorithm
```
1. Find all healthy sources
2. Select the lowest index (highest priority)
3. If higher priority than current → check revert conditions
4. If conditions met → auto-revert
5. Otherwise → stay on current source
```

### Revert Conditions
```
ALL must be true:
- auto_revert_enabled = 1
- best_source < active_source (higher priority available)
- time_since_healthy >= revert_stability_time_ms (source is stable)
- time_since_last_revert >= revert_cooldown_ms (cooldown expired)
```

### Backward Compatibility
- ✅ Disabled by default (`msw_auto_revert=0`)
- ✅ Existing behavior unchanged when disabled
- ✅ No breaking changes to API or options

---

## 📊 Testing Scenarios

### Scenario 1: Basic Revert
```bash
# Source 0 (preferred) → Source 1 → Source 0 recovers → revert
./ffmpeg -f mswitchdirect \
  -msw_sources "srt://source0:9000,srt://source1:9000" \
  -msw_auto_failover 1 \
  -msw_auto_revert 1 \
  -msw_revert_delay 5000 \
  -i dummy -c copy output.mp4
```

**Expected:**
1. Start on Source 0
2. Kill Source 0 → failover to Source 1 (instant)
3. Restart Source 0 → revert to Source 0 (after 5s + 3s stability)

### Scenario 2: Flapping Source
```bash
# Source 0 flaps → should NOT revert until stable
```

**Expected:**
1. Source 0 dies → failover to Source 1
2. Source 0 recovers for 1s, dies again → NO revert
3. Source 0 recovers and stays healthy for 3s → revert

### Scenario 3: Disabled (Default)
```bash
# No auto-revert when disabled
./ffmpeg -f mswitchdirect \
  -msw_sources "srt://source0:9000,srt://source1:9000" \
  -msw_auto_failover 1 \
  -i dummy -c copy output.mp4
```

**Expected:**
1. Source 0 → Source 1 → Source 0 recovers → **stay on Source 1**

---

## 🎯 Success Criteria

- ✅ Auto-revert works reliably when enabled
- ✅ No thrashing on flapping sources
- ✅ Backward compatible (disabled by default)
- ✅ Smooth transitions (no frame drops)
- ✅ Clear logging for debugging
- ✅ Comprehensive documentation
- ✅ All tests pass

---

## 📦 Delivery

- **Branch**: `feature/auto-revert-preferred-source`
- **PR**: Create when ready
- **Release**: v1.5.0 (new feature)

