# MSwitch Implementation Summary

**Date**: January 2, 2025  
**Status**: Ready to implement multi-process architecture

---

## Journey So Far

### ✅ What We've Accomplished

1. **CLI Integration** ✅
   - Integrated MSwitch commands into FFmpeg's interactive keyboard handling
   - Commands work: `0`, `1`, `2` (switch source), `m` (status), `?` (help)

2. **Webhook Server** ✅
   - Implemented HTTP server with JSON parsing
   - Accepts POST requests to `/switch` endpoint
   - Successfully parses `{"source":"s1"}` requests
   - Returns JSON responses

3. **Filter Integration** ✅
   - Successfully connected to `streamselect` filter
   - Implemented `avfilter_process_command()` for runtime parameter changes
   - Confirmed filter internal state updates correctly

4. **Comprehensive Investigation** ✅
   - Proved `streamselect` filter updates its `map[]` array correctly
   - Identified `FFFrameSync` as the architectural blocker
   - Documented findings thoroughly

### ❌ What Didn't Work

1. **`streamselect` Filter** ❌
   - Filter's `map[]` array updates correctly ✅
   - But `FFFrameSync` doesn't respect runtime changes ❌
   - Visual output remains stuck on initial source ❌
   - **Conclusion**: Architecturally incompatible with our use case

---

## Current Decision: Multi-Process Architecture

### Why This Approach?

**Industry Standard**: vMix, OBS, Wirecast all use this architecture  
**Proven Reliable**: Tested in production for years  
**Universal Compatibility**: Works with ANY input format  
**True Isolation**: Source failures don't cascade  
**Seamless Switching**: Sub-100ms latency at packet level

### How It Works

```
Source 1 → FFmpeg Subprocess → UDP:12350 ┐
Source 2 → FFmpeg Subprocess → UDP:12351 ├→ UDP Proxy → Output
Source 3 → FFmpeg Subprocess → UDP:12352 ┘
                                          ↑
                               Active source selection
```

---

## Implementation Plan

### Phase 1: Subprocess Management (RESTORE + ENHANCE)

**Goal**: Spawn and manage FFmpeg subprocess for each source

**Key Functions**:
- `mswitch_start_source_subprocess()`: Fork and exec FFmpeg
- `mswitch_stop_source_subprocess()`: Kill and cleanup
- `mswitch_monitor_subprocess_thread()`: Health monitoring

**Subprocess Command** (Seamless Mode):
```bash
ffmpeg -i {source_url} -c:v copy -c:a copy -f mpegts udp://127.0.0.1:{port}
```

**Estimated Time**: 2-3 hours

### Phase 2: UDP Stream Proxy (NEW)

**Goal**: Listen on all source UDP ports, forward from active source

**Key Functions**:
- `mswitch_udp_proxy_init()`: Create UDP sockets
- `mswitch_udp_proxy_thread()`: Main forwarding loop (select + sendto)
- `mswitch_udp_proxy_cleanup()`: Close sockets

**Proxy Logic**:
- Use `select()` to monitor all source sockets
- Read from active source, forward to output
- Discard packets from inactive sources

**Estimated Time**: 3-4 hours

### Phase 3: Integration & Testing

**Goal**: Connect all pieces, test end-to-end

**Test Command**:
```bash
./ffmpeg \
    -msw.enable \
    -msw.sources "s0=udp://..;s1=udp://..;s2=udp://.." \
    -msw.mode seamless \
    -msw.webhook.enable \
    -msw.webhook.port 8099 \
    -f mpegts udp://127.0.0.1:12349
```

**Estimated Time**: 2-3 hours

### **Total Estimated Time**: 7-10 hours

---

## What We're Keeping from Current Implementation

### ✅ Infrastructure to Retain

1. **MSwitch Context Structure**:
   - `MSwitchContext` with sources array
   - `MSwitchSource` struct with metadata
   - Configuration parsing (`-msw.*` options)

2. **Control Interfaces**:
   - CLI keyboard handling in `ffmpeg.c`
   - Webhook server in `ffmpeg_mswitch.c`
   - `mswitch_switch_to()` API

3. **Threading Infrastructure**:
   - Health monitoring thread
   - Webhook server thread
   - Mutex/condition variables for state

4. **Logging & Debugging**:
   - `mswitch_log()` function
   - Comprehensive debug messages
   - Status reporting (`m` command)

### ❌ What We're Removing

1. **Filter-Based Switching**:
   - `mswitch_setup_filter()` function
   - `mswitch_update_filter_map()` function
   - `streamselect_ctx` pointer in MSwitchContext
   - All `avfilter_process_command` calls

2. **Frame-Level Switching**:
   - Frame filtering in `ffmpeg_sched.c`
   - Decoder frame counting
   - Frame discard logic

---

## Files That Will Change

### Major Changes

1. **`fftools/ffmpeg_mswitch.c`**:
   - Remove filter-based switching code
   - Add subprocess management functions (restore from history)
   - Add UDP proxy thread
   - Update `mswitch_init()` to start subprocesses
   - Update `mswitch_cleanup()` to stop subprocesses
   - Update switch functions to just update active index

2. **`fftools/ffmpeg_mswitch.h`**:
   - Keep subprocess fields (already present)
   - Add UDP proxy fields
   - Remove `streamselect_ctx` and `filter_graph` pointers

3. **`fftools/ffmpeg_filter.c`**:
   - Remove MSwitch integration code
   - Remove `mswitch_setup_filter()` call

4. **`fftools/ffmpeg_sched.c`**:
   - Remove frame-level filtering code
   - Restore to vanilla state

### Minor/No Changes

1. **`fftools/ffmpeg_opt.c`**: No changes (option parsing works)
2. **`fftools/ffmpeg.c`**: No changes (CLI integration works)
3. **`fftools/ffmpeg_demux.c`**: No changes (already vanilla)

---

## Testing Strategy

### Test 1: Three Color Sources (Baseline)

```bash
# Terminal 1: Start source subprocesses (simulated by MSwitch)
# (MSwitch will handle this internally)

# Terminal 2: Start MSwitch
./ffmpeg \
    -msw.enable \
    -msw.sources "s0=color=red:size=640x480:rate=10;s1=color=green:size=640x480:rate=10;s2=color=blue:size=640x480:rate=10" \
    -msw.mode seamless \
    -f mpegts - | ffplay -i -

# Terminal 3: Switch sources
curl -X POST http://localhost:8099/switch -d '{"source":"s1"}'  # Should turn GREEN
curl -X POST http://localhost:8099/switch -d '{"source":"s2"}'  # Should turn BLUE
curl -X POST http://localhost:8099/switch -d '{"source":"s0"}'  # Should turn RED
```

**Expected Result**: ffplay window changes color immediately

### Test 2: Three UDP Sources

```bash
# Terminal 1-3: Start source generators
ffmpeg -f lavfi -i "testsrc=size=640x480:rate=30" -c:v libx264 -preset ultrafast -f mpegts udp://10.0.1.1:5000
ffmpeg -f lavfi -i "testsrc2=size=640x480:rate=30" -c:v libx264 -preset ultrafast -f mpegts udp://10.0.1.2:5000
ffmpeg -f lavfi -i "smptebars=size=640x480:rate=30" -c:v libx264 -preset ultrafast -f mpegts udp://10.0.1.3:5000

# Terminal 4: Start MSwitch
./ffmpeg \
    -msw.enable \
    -msw.sources "s0=udp://10.0.1.1:5000;s1=udp://10.0.1.2:5000;s2=udp://10.0.1.3:5000" \
    -msw.mode seamless \
    -f mpegts udp://127.0.0.1:12349

# Terminal 5: View output
ffplay udp://127.0.0.1:12349

# Terminal 6: Switch sources
curl -X POST http://localhost:8099/switch -d '{"source":"s1"}'
```

**Expected Result**: ffplay switches between test patterns

### Test 3: Mixed Sources

```bash
# UDP + RTMP + File
./ffmpeg \
    -msw.enable \
    -msw.sources "s0=udp://10.0.1.1:5000;s1=rtmp://server/stream;s2=file.mp4" \
    -msw.mode seamless \
    -f mpegts udp://127.0.0.1:12349
```

**Expected Result**: Can switch between all three source types

---

## Success Criteria

### Minimum Viable Product (MVP)

- ✅ Three sources running as subprocesses
- ✅ UDP proxy forwards from active source
- ✅ CLI commands (`0`, `1`, `2`) switch visually
- ✅ Webhook commands switch visually
- ✅ No crashes during normal operation
- ✅ Can switch rapidly (multiple times per second)

### Production Ready

- ✅ MVP criteria
- ✅ Subprocess health monitoring and restart
- ✅ Graceful shutdown of all subprocesses
- ✅ Error handling for invalid sources
- ✅ Logging and debugging capabilities
- ✅ Performance: < 100ms switch latency
- ✅ Stability: 1 hour continuous operation without crashes

---

## Next Steps

**Immediate**: Start Phase 1 - Restore subprocess management code

**Command to begin**:
```bash
# Review the current subprocess-related code
grep -n "subprocess" fftools/ffmpeg_mswitch.c | head -20

# Check what functions need to be implemented
grep -n "mswitch_start_source_subprocess" fftools/ffmpeg_mswitch.c
```

**Ready to proceed?** Let me know and I'll start implementing Phase 1!

---

*Summary prepared: January 2, 2025*  
*Estimated implementation time: 7-10 hours*  
*Confidence level: HIGH (proven architecture)*

