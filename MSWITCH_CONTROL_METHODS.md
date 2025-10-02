# MSwitch Control Methods

This document describes the different ways to control source switching in the MSwitch video filter.

## Overview

The `mswitch` filter supports multiple control methods for switching between video sources in real-time:

1. **Timeline-based (sendcmd)** - Pre-defined switching schedule
2. **File-based Commands** - Dynamic command queue
3. **CLI (Command Line)** - Interactive keyboard control (legacy MSwitch)
4. **Webhook (HTTP API)** - Remote REST API control (legacy MSwitch)

---

## Method 1: Timeline-based Switching (sendcmd)

**Status**: ✅ **Production-Ready** | **Working**

### Description
Pre-define a complete switching timeline before encoding starts. Best for:
- Automated switching at specific times
- Repeatable demos and presentations
- Testing and validation

### Example
```bash
# Create timeline file
cat > /tmp/timeline.txt << 'EOF'
0.0 mswitch map 0;
5.0 mswitch map 1;
10.0 mswitch map 2;
15.0 mswitch map 0;
EOF

# Use with FFmpeg
ffmpeg \
    -f lavfi -i "color=red:size=1280x720:rate=30" \
    -f lavfi -i "color=green:size=1280x720:rate=30" \
    -f lavfi -i "color=blue:size=1280x720:rate=30" \
    -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0[sw];
                     [sw]sendcmd=f=/tmp/timeline.txt[out]" \
    -map "[out]" output.mp4
```

### Timeline File Format
```
<timestamp> mswitch map <input_index>;
```
- `timestamp`: Time in seconds (e.g., 0.0, 5.5, 10.0)
- `input_index`: Source index (0-based, e.g., 0, 1, 2)

### Demo Script
```bash
./tests/test_mswitch_live_simple.sh
./tests/test_mswitch_live_realtime.sh
```

### Pros
- ✅ Frame-precise timing
- ✅ Repeatable
- ✅ No runtime dependencies
- ✅ Simple to understand

### Cons
- ❌ Timeline must be known in advance
- ❌ Cannot react to runtime events
- ❌ Cannot modify after encoding starts

---

## Method 2: File-based Command Queue

**Status**: ✅ **Experimental** | **Partially Working**

### Description
Append commands to a file while FFmpeg is running. The `sendcmd` filter reads the file continuously. Best for:
- Scripted automation
- External control systems
- Event-driven switching

### Example
```bash
# Start FFmpeg with sendcmd watching a file
CMD_FILE="/tmp/mswitch_commands.txt"
echo "0.0 mswitch map 0;" > "$CMD_FILE"

ffmpeg ... -filter_complex "...sendcmd=f=$CMD_FILE..." ... &

# In another terminal, add commands dynamically
echo "5.0 mswitch map 1;" >> "$CMD_FILE"
echo "10.0 mswitch map 2;" >> "$CMD_FILE"
```

### Demo Script
```bash
./tests/test_mswitch_sendcmd_file.sh
```

### Pros
- ✅ Can add commands while running
- ✅ Script-friendly
- ✅ No special protocols

### Cons
- ❌ Timing must be relative to stream start
- ❌ Commands cannot be removed once added
- ❌ Limited real-time responsiveness

---

## Method 3: CLI (Interactive Keyboard)

**Status**: ⚠️  **Legacy MSwitch** | **Requires Old Implementation**

### Description
Type commands directly into the FFmpeg terminal. This uses the legacy MSwitch implementation (not the `mswitch` filter). Best for:
- Manual testing
- Live operator control
- Quick demos

### Interactive Commands
```
0, 1, 2, 3  - Switch to source 0, 1, 2, or 3
m           - Show MSwitch status
q           - Quit
```

### Example
```bash
ffmpeg \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local" \
    -msw.cli.enable \
    -i input0.mp4 -i input1.mp4 -i input2.mp4 \
    -map 0:v -map 1:v -map 2:v \
    output.ts
    
# Type 0, 1, 2 to switch sources
# Type m to see status
# Type q to quit
```

### Demo Script
```bash
./tests/test_mswitch_cli_control.sh
```

### Implementation Note
This requires the legacy MSwitch context (`global_mswitch_ctx`) and keyboard handling in `fftools/ffmpeg.c`. The keyboard commands are integrated into FFmpeg's main `check_keyboard_interaction()` function.

### Pros
- ✅ Immediate response
- ✅ Simple to use
- ✅ No external tools needed

### Cons
- ❌ Requires legacy MSwitch (not `mswitch` filter)
- ❌ Must have terminal in foreground
- ❌ Not suitable for automation
- ❌ Single-character commands only

---

## Method 4: Webhook (HTTP API)

**Status**: ⚠️  **Legacy MSwitch** | **Requires Old Implementation**

### Description
Control switching via HTTP POST requests. This uses the legacy MSwitch implementation with a built-in HTTP server. Best for:
- Remote control
- Web interfaces
- Integration with automation systems
- Multi-user control

### API Endpoint
```
POST http://localhost:8099/switch
Content-Type: application/json

{"source": "s1"}
```

### Example
```bash
# Start FFmpeg with webhook enabled
ffmpeg \
    -msw.enable \
    -msw.sources "s0=udp://...; s1=udp://...; s2=udp://..." \
    -msw.webhook.enable \
    -msw.webhook.port 8099 \
    ...

# In another terminal, send switch commands
curl -X POST http://localhost:8099/switch \
     -H "Content-Type: application/json" \
     -d '{"source":"s1"}'

curl -X POST http://localhost:8099/switch \
     -H "Content-Type: application/json" \
     -d '{"source":"s2"}'
```

### Demo Script
```bash
./tests/test_mswitch_webhook_control.sh
```

### Source IDs
- Format: `s0`, `s1`, `s2`, `s3`, etc.
- Must match the source IDs defined in `-msw.sources`

### Implementation Note
This requires:
- Legacy MSwitch context in `fftools/ffmpeg_mswitch.c`
- HTTP server thread (`mswitch_webhook_server_thread`)
- Socket includes and pthread library

### Pros
- ✅ Remote control from anywhere
- ✅ REST API standard
- ✅ Language-agnostic
- ✅ Can integrate with web UIs
- ✅ Multiple clients can send commands

### Cons
- ❌ Requires legacy MSwitch (not `mswitch` filter)
- ❌ Requires HTTP server thread
- ❌ Network-dependent
- ❌ Security considerations (no auth by default)

---

## Comparison Table

| Method | Real-time | Pre-planned | Remote | Automation | Filter | Status |
|--------|-----------|-------------|--------|------------|--------|--------|
| Timeline (sendcmd) | ❌ | ✅ | ❌ | ✅ | `mswitch` | ✅ Working |
| File Queue | ~⚠️ | ~⚠️ | ❌ | ✅ | `mswitch` | ⚠️ Experimental |
| CLI | ✅ | ❌ | ❌ | ❌ | Legacy | ⚠️ Legacy only |
| Webhook | ✅ | ❌ | ✅ | ✅ | Legacy | ⚠️ Legacy only |

---

## Recommendations

### For Production Use
**Use Timeline-based switching (Method 1)** with the `mswitch` filter:
- Most reliable and tested
- Frame-perfect timing
- No external dependencies
- Works with current implementation

### For Development/Testing
**Use Timeline-based switching** or **File-based queue**:
- Both work with the `mswitch` filter
- Easy to script and automate
- Repeatable results

### For Future Enhancement
**Implement new webhook/CLI for `mswitch` filter**:
The current CLI and webhook implementations work with the legacy MSwitch context, not the new `mswitch` filter. To enable real-time remote control with the filter:

1. Create a ZMQ or named pipe interface for `mswitch` filter
2. Implement `avfilter_process_command()` calls from external source
3. Add HTTP server that sends commands to the filter
4. Integrate with FFmpeg's interactive command system

---

## Demo Scripts Summary

All demo scripts are in `/tests/`:

| Script | Method | Duration | Interactive | Status |
|--------|--------|----------|-------------|--------|
| `test_mswitch_live_simple.sh` | Timeline | 45s | No | ✅ Working |
| `test_mswitch_live_realtime.sh` | Timeline | 50s | No | ✅ Working |
| `test_mswitch_live_demo.sh` | Timeline | 60s | No | ✅ Working |
| `test_mswitch_sendcmd_file.sh` | File Queue | 40s | No | ⚠️ Experimental |
| `test_mswitch_cli_control.sh` | CLI | ∞ | Yes | ⚠️ Legacy MSwitch |
| `test_mswitch_webhook_control.sh` | Webhook | ∞ | Via curl | ⚠️ Legacy MSwitch |
| `test_mswitch_live_control.sh` | Timeline | 5min | No | ✅ Working |

---

## Implementation Details

### mswitch Filter (Current)
- Located in: `libavfilter/vf_mswitch.c`
- Control via: `sendcmd` filter
- Command format: `mswitch map <index>`
- Runtime command handler: `process_command()` function

### Legacy MSwitch Context (Old)
- Located in: `fftools/ffmpeg_mswitch.c`, `fftools/ffmpeg_mswitch.h`
- Control via: Built-in CLI and webhook
- Integrated with: FFmpeg main loop and decoder selection
- Status: Deprecated in favor of filter-based approach

---

## Future Enhancements

Potential improvements for the `mswitch` filter:

1. **ZMQ Interface**
   - Real-time command interface
   - Pub/sub pattern for multiple controllers
   - Language bindings available

2. **Named Pipe/FIFO**
   - Simple real-time control
   - No network dependency
   - Command queue with immediate processing

3. **HTTP Server Filter**
   - REST API for filter control
   - Similar to legacy webhook but filter-native
   - Standard JSON API

4. **Interactive Command Integration**
   - Extend FFmpeg's `check_keyboard_interaction()`
   - Direct keyboard control for filter
   - Status display and monitoring

---

## Getting Started

### Quick Test (5 minutes)
```bash
# Download Big Buck Bunny (if not already done)
cd /tmp && mkdir -p mswitch_demo
curl -L -o /tmp/mswitch_demo/big_buck_bunny.mp4 \
     "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"

# Run the simplest demo
cd /path/to/FFmpeg
./tests/test_mswitch_live_simple.sh
```

You should see:
- Red screen for 10 seconds
- Big Buck Bunny movie for 20 seconds  
- Blue screen for 15 seconds

All switching is automatic and pre-programmed!

---

## Questions?

For issues or feature requests, see:
- `MSWITCH_FILTER_SUCCESS.md` - Complete filter documentation
- `IDR_DETECTION_SUCCESS.md` - Custom demuxer details
- `tests/` directory - All demo scripts with examples

**Repository**: https://github.com/yarontorbaty/FFmpeg-MSwitch

