# Freeze-Frame Failover Implementation

## Overview

The freeze-frame failover approach provides **instantaneous, seamless failover** without black screens or interim sources. When a source fails, the system immediately repeats the last successfully decoded frame while the health monitor finds a healthy replacement source in the background.

## How It Works

### 1. **Last Good Packet Storage**
- Every time a packet is successfully read from a source, it's stored as `last_good_packet`
- This packet is kept in memory for each source independently
- Minimal memory overhead (~few KB per source for one packet)

### 2. **Source Failure Detection**
- When `packet_buffer_get()` returns `AVERROR_EOF` for the active source
- System checks if `last_good_packet` is available
- If yes → Enter freeze-frame mode
- If no → Fall back to immediate failover (old behavior)

### 3. **Freeze-Frame Mode**
```
Source fails → Check last_good_packet
              ↓
         ✅ Available
              ↓
    Enter FREEZE-FRAME mode
              ↓
    Repeat last packet with incremented timestamps
              ↓
    Health monitor finds healthy source (background)
              ↓
    Set pending_switch_to
              ↓
    Wait for I-frame from new source
              ↓
    Switch on I-frame
              ↓
    Exit freeze-frame mode
```

### 4. **Timestamp Continuity**
- Freeze-frame packets use incremented timestamps:
  ```c
  pkt->pts = last_output_pts + freeze_frame_duration
  pkt->dts = last_output_dts + freeze_frame_duration
  ```
- `freeze_frame_duration` = duration of one frame (e.g., 3000 ticks for 30fps at 90kHz timebase)
- Ensures smooth timestamp progression during freeze
- No DTS/PTS discontinuities

### 5. **Background Health Monitoring**
- Health monitor continues running during freeze-frame
- Checks all sources for recovery
- When healthy source found → sets `pending_switch_to`
- `read_packet` detects pending switch and executes on I-frame

### 6. **Exit Freeze-Frame**
- Automatically exits when:
  - Successful switch to healthy source
  - Original source recovers (starts sending packets again)
- Logs: `✅ Source X recovered, exiting freeze-frame mode`

## Advantages Over Black Interim File

| Aspect | Freeze-Frame | Black Interim File |
|--------|--------------|-------------------|
| **Latency** | Instantaneous | Requires switch + decode |
| **Complexity** | Simple | Two-stage failover |
| **Resources** | Minimal (one packet) | Full demuxer + decoder |
| **Visual** | Last real frame | Black screen |
| **Timestamp** | Continuous | Needs normalization |
| **Grace Period** | Not needed | Needed (3 seconds) |
| **Health Checks** | Works normally | Skip for black file |

## Key Benefits

1. **✅ Truly Instantaneous** - No switching delay, just repeat last packet
2. **✅ No Black Screen** - Viewer sees frozen frame, not black
3. **✅ Simpler Logic** - No two-stage failover, no special cases for interim source
4. **✅ Lower Resource** - No extra demuxer/decoder for black file
5. **✅ Timestamp Continuity** - Natural progression, no complex normalization
6. **✅ Graceful Degradation** - Falls back to immediate failover if no last packet

## Code Changes

### Data Structures
```c
typedef struct MSwitchSource {
    // ... existing fields ...
    
    // Freeze-frame support
    AVPacket *last_good_packet;    // Last successfully read packet
    int has_good_packet;           // Whether we have a valid last_good_packet
} MSwitchSource;

typedef struct MSwitchDirectContext {
    // ... existing fields ...
    
    int freeze_frame_active;       // Currently in freeze-frame mode
    int64_t freeze_frame_duration; // Duration of one frame (for timestamp increment)
} MSwitchDirectContext;
```

### Initialization
- `last_good_packet = NULL`
- `has_good_packet = 0`
- `freeze_frame_active = 0`
- `freeze_frame_duration = 3000` (30fps default)

### Read Packet Logic
1. Try to read from active source
2. If EOF:
   - Check `has_good_packet`
   - If yes: Enter freeze-frame, repeat packet with incremented timestamps
   - If no: Fall back to immediate failover
3. If success:
   - Store as `last_good_packet`
   - Exit freeze-frame if active

### Cleanup
- Free `last_good_packet` in `read_close`

## Testing

Run the test script:
```bash
./tests/test_freeze_frame_failover.sh
```

**Expected behavior:**
1. Source 0 (red) active
2. Stop source 0 → See "❄️ entering FREEZE-FRAME mode"
3. Output shows frozen red frame (not black!)
4. Health monitor finds source 1 (green)
5. Smooth switch to green on I-frame
6. "✅ SWITCHED: Source 0 → 1"

## Log Messages

- `❄️  Source X failed, entering FREEZE-FRAME mode` - Freeze-frame activated
- `❄️  Freeze-frame: repeating last packet (pts=..., dts=...)` - Outputting frozen frame
- `✅ Source X recovered, exiting freeze-frame mode` - Original source recovered
- `✅ SWITCHED: Source X → Y` - Successfully switched to healthy source (exits freeze-frame)

## Future Enhancements

1. **Adaptive Frame Duration** - Calculate from actual stream timebase
2. **Freeze-Frame Timeout** - Force switch after X seconds even without I-frame
3. **Visual Indicator** - Add watermark/overlay during freeze-frame
4. **Statistics** - Track freeze-frame duration, frequency
5. **Multi-Codec Support** - Extend beyond H.264 (HEVC, AV1, etc.)

## Comparison with Broadcast Systems

This approach mirrors professional broadcast systems:
- **Broadcast**: Hold last frame on signal loss
- **Our Implementation**: Repeat last packet on source failure
- **Result**: Seamless, professional-grade failover

## Removed Components

With freeze-frame, we can now remove:
- `black_loop.ts` / `black_interim.ts` files
- Two-stage failover logic
- Black file health check exemptions
- Manual switch grace period (for black file)
- Black file as "last source" special handling

The codebase is now **simpler, faster, and more robust**! 🎉
