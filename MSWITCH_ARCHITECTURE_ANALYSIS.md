# MSwitch Native Implementation - Architecture Analysis

## Executive Summary

The native MSwitch implementation has been successfully developed with functional **logical switching** (the `active_source_index` changes correctly), but **visual switching** (actual output change) is not working due to fundamental FFmpeg architecture constraints.

## What's Working ✅

### 1. Command-Line Interface
- Successfully parses `-msw.*` options
- Correctly initializes MSwitch with multiple sources
- Interactive CLI commands (0/1/2) work

### 2. Webhook Server
- HTTP server listening on port 8099
- Correctly parses JSON requests: `POST /switch {"source":"s1"}`
- Calls `mswitch_switch_to()` and updates `active_source_index`
- Returns proper HTTP responses

### 3. Frame-Level Filtering
- Implemented in `fftools/ffmpeg_sched.c` (`sch_dec_send` function)
- Correctly identifies active source changes
- Logs: `[MSwitch] ACTIVE SOURCE CHANGED: 0 -> 1`
- Discards frames from inactive decoders

### 4. Multi-Decoder Execution
- All 3 decoders run simultaneously
- Command structure forces all decoders to start:
  ```bash
  -map 0:v -c:v libx264 ... output.ts  # Real output
  -map 1:v -f null -                    # Dummy output (keeps decoder 1 running)
  -map 2:v -f null -                    # Dummy output (keeps decoder 2 running)
  ```

## What's NOT Working ❌

### Visual Switching Fails

**Test Evidence:**
- All captured JPEG frames are identical size (2.0K or 674 bytes)
- Active source changes from 0 → 1 → 2 in logs
- But output always shows frames from decoder 0 (RED color)

**Root Cause:**
FFmpeg's stream mapping (`-map 0:v`) creates a **static, compile-time binding** between:
- **Decoder 0** → **Encoder 0** → **Output 0**

This binding is established during initialization and **cannot be changed at runtime**.

## Architecture Constraint Analysis

### FFmpeg's Pipeline Architecture

```
Input 0 → Demuxer 0 → Decoder 0 ──┐
Input 1 → Demuxer 1 → Decoder 1 ──┼──→ ??? → Encoder 0 → Muxer 0 → Output
Input 2 → Demuxer 2 → Decoder 2 ──┘
```

**The Problem:**
- The `???` (routing decision) is made during **initialization**, not at runtime
- `-map 0:v` means "route decoder 0's output to encoder 0"
- This routing is hardcoded in FFmpeg's scheduler data structures

### Current Frame Filtering Approach

In `fftools/ffmpeg_sched.c`:
```c
if (global_mswitch_enabled && dec_idx != active_source) {
    av_frame_unref(frame);  // Discard frame from inactive decoder
    return 0;
}
```

**What this does:**
- ✅ Prevents inactive decoders' frames from being encoded
- ❌ Does NOT route active non-zero decoder frames to encoder 0

**Why it fails:**
- Decoder 1's frames go to Encoder 1 (mapped via `-map 1:v`)
- Encoder 1 outputs to `/dev/null` (via `-f null -`)
- Encoder 0 only receives frames from Decoder 0
- When we discard Decoder 0's frames, Encoder 0 gets **nothing**, not frames from Decoder 1

## Solution Approaches

### Option 1: Frame Redirection (Requires Deep Scheduler Modification)

**Concept:** Dynamically redirect frames from active decoder to encoder 0

**Implementation:**
```c
// In sch_dec_send(), after determining active source:
if (dec_idx == active_source && dec_idx != 0) {
    // Redirect this frame to encoder 0's input
    // This requires modifying o->dst[] routing table
    // PROBLEM: dst[] is const and set during initialization
}
```

**Challenges:**
- FFmpeg's scheduler uses `SchDecOutput` structures with `dst[]` arrays
- These are set during `sch_connect()` calls at initialization
- Changing routing at runtime requires:
  1. Modifying const structures
  2. Managing encoder states (timestamps, frame numbers)
  3. Handling codec context (decoder format must match encoder expectations)

**Feasibility:** 🔴 **Very Difficult**
- Requires extensive FFmpeg internals knowledge
- High risk of breaking other FFmpeg features
- May cause timestamp/sync issues

### Option 2: Filter-Based Switching (Recommended) ⭐

**Concept:** Use FFmpeg's filter graph to dynamically select input

**Command Structure:**
```bash
ffmpeg \
  -i source0 -i source1 -i source2 \
  -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
  -map "[out]" -c:v libx264 output.ts
```

**How it works:**
- `streamselect` filter can change its `map` parameter at runtime
- MSwitch updates the filter's map value via `av_opt_set()`
- All 3 inputs feed the filter, it selects which one passes through

**Implementation:**
1. Create filter graph with `streamselect` during initialization
2. In `mswitch_switch_to()`, call:
   ```c
   char map_str[8];
   snprintf(map_str, sizeof(map_str), "%d", target_index);
   av_opt_set(streamselect_ctx, "map", map_str, 0);
   ```

**Feasibility:** 🟢 **Practical**
- Uses FFmpeg's existing filter infrastructure
- No scheduler modifications needed
- Filters are designed for runtime parameter changes

**Challenges:**
- Need to expose filter context to MSwitch
- Must handle synchronization (filters buffer frames)
- Graceful switching may have transition artifacts

### Option 3: Subprocess Architecture (Most Robust) ⭐⭐

**Concept:** MSwitch spawns FFmpeg subprocesses for each source

**Architecture:**
```
┌─ Source 0 Subprocess ─┐      ┌─ MSwitch Main Process ─┐
│ ffmpeg -i src0 → UDP  │──┐   │                         │
└───────────────────────┘  │   │  ┌──UDP Proxy──────┐   │
                           ├──→│  │ Receive from    │   │
┌─ Source 1 Subprocess ─┐  │   │  │ active source   │   │
│ ffmpeg -i src1 → UDP  │──┤   │  │ Forward to      │   │
└───────────────────────┘  │   │  │ encoder         │   │
                           │   │  └─────────────────┘   │
┌─ Source 2 Subprocess ─┐  │   │         ↓              │
│ ffmpeg -i src2 → UDP  │──┘   │    Encode & Output     │
└───────────────────────┘      └────────────────────────┘
```

**How it works:**
- Each source runs in its own FFmpeg process
- All output compressed streams to unique UDP ports
- MSwitch main process:
  - Listens on all source UDP ports
  - Reads packets from active source
  - Forwards to single output port
  - Main encoder reads from that output port

**Advantages:**
- ✅ True source isolation (crash in one doesn't affect others)
- ✅ Each source can have different codecs, resolutions
- ✅ Switching is true packet-level (seamless mode works perfectly)
- ✅ Proven architecture (used by vMix, OBS, Wirecast)

**Implementation Path:**
1. Restore subprocess management code (previously removed)
2. Implement UDP proxy/forwarder thread
3. Main process reads from single UDP port
4. Switching just changes which source's packets are forwarded

**Feasibility:** 🟢 **Highly Feasible**
- Already partially implemented (code exists but disabled)
- Clean separation of concerns
- Scales to any number of sources

### Option 4: Custom Demuxer (Advanced)

**Concept:** Create a "multi-source demuxer" that presents as single input

**How it works:**
```bash
ffmpeg -i "mswitch://s0=udp://..;s1=udp://..;s2=udp://.." \
  -c:v libx264 output.ts
```

- Custom demuxer opens all sources internally
- Presents single stream to FFmpeg
- Switches sources internally based on MSwitch state

**Feasibility:** 🟡 **Complex but Clean**
- Requires implementing custom AVInputFormat
- Most architecturally clean solution
- Switching completely hidden from FFmpeg core

## Recommendation

### Short Term: **Option 2 (Filter-Based)**
Best for quick implementation and testing

**Pros:**
- Can be implemented in 1-2 hours
- Uses existing FFmpeg infrastructure
- No major architectural changes

**Cons:**
- Limited to same codec/format sources
- May have buffering/sync issues

### Long Term: **Option 3 (Subprocess Architecture)**
Best for production-quality implementation

**Pros:**
- Most robust and scalable
- Supports any source types
- Industry-proven approach

**Cons:**
- More code to maintain
- Higher system resource usage

## Implementation Priority

1. **Immediate:** Fix current approach to at least demonstrate concept
   - Implement Option 2 (filter-based switching)
   - Document limitations clearly

2. **Next Sprint:** Implement Option 3 (subprocess architecture)
   - Re-enable subprocess code
   - Implement UDP proxy
   - Full end-to-end testing

3. **Future:** Consider Option 4 (custom demuxer)
   - Only if clean API needed
   - If distributing as library

## Test Results Summary

### Logical Switching: ✅ WORKING
```
[MSwitch] [Webhook] *** SWITCHING TO SOURCE: s1 ***
[MSwitch] Switching from source 0 to source 1 (s1)
[MSwitch] [Webhook] Switch result: 0
[MSwitch] ACTIVE SOURCE CHANGED: 0 -> 1
```

### Visual Switching: ❌ NOT WORKING
```
Before switch: frame_0001.jpg (2.0K) - RED
After switch:  frame_0007.jpg (2.0K) - RED (should be GREEN)
```

### Frame Counts:
```
Initial:       dec0=1,    dec1=1,    dec2=1
After switch:  dec0=20,   dec1=2002505, dec2=1985206
```
- Decoder 1 processed 2M+ frames (running correctly)
- But these frames never reached the output

## Files Modified

- `fftools/ffmpeg_sched.c`: Frame-level filtering in `sch_dec_send()`
- `fftools/ffmpeg_mswitch.c`: Webhook server with JSON parsing
- `fftools/ffmpeg_mswitch.h`: MSwitch context structures
- `fftools/ffmpeg_opt.c`: Command-line option parsing
- `fftools/ffmpeg.c`: Interactive CLI integration

## Command Structure (Current)

```bash
./ffmpeg \
  -msw.enable \
  -msw.sources "s0=url1;s1=url2;s2=url3" \
  -msw.mode graceful \
  -msw.ingest hot \
  -msw.webhook.enable \
  -msw.webhook.port 8099 \
  -i url1 -i url2 -i url3 \
  -map 0:v -c:v libx264 -f mpegts output.ts \  # Real output (always decoder 0)
  -map 1:v -f null - \                          # Dummy (keeps decoder 1 alive)
  -map 2:v -f null -                            # Dummy (keeps decoder 2 alive)
```

**Status:** Logical switching works, visual switching does not.

---

**Date:** 2025-10-02  
**Author:** AI Assistant  
**FFmpeg Version:** N-121297-g0c97cbeb22

