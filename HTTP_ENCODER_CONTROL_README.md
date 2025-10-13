# HTTP-Based Encoder Control for libx264

## Overview

This feature allows **runtime control** of the libx264 encoder via HTTP commands. You can dynamically adjust:
- **Bitrate** (with VBV parameters)
- **Framerate** (FPS)
- **Force IDR frames**

This is useful for testing encoder responsiveness, adaptive streaming scenarios, and debugging rate control behavior.

## Architecture

```
┌─────────────────┐
│  HTTP Client    │  (curl, scripts, etc.)
│  (Port 8080)    │
└────────┬────────┘
         │ POST {"bitrate":5000}
         ▼
┌─────────────────────────┐
│ encoder_control.c       │
│ HTTP Server Thread      │
│ - Parses JSON commands  │
│ - Queues to encoder     │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ libx264.c               │
│ X264_frame()            │
│ - Checks for commands   │
│ - Calls x264_encoder_   │
│   reconfig()            │
│ - Logs results          │
└─────────────────────────┘
```

## Usage

### 1. Enable HTTP Control in FFmpeg Command

Add these options to your libx264 encoder:

```bash
ffmpeg -i input.mp4 \\
    -c:v libx264 \\
    -http_control_enable 1 \\
    -http_control_port 8080 \\
    output.mp4
```

### 2. Send Control Commands via HTTP

Use `curl` to send JSON commands:

#### Change Bitrate
```bash
curl -X POST http://localhost:8080 \\
    -H "Content-Type: application/json" \\
    -d '{"bitrate":5000}'  # 5000 kbps
```

#### Change Framerate
```bash
curl -X POST http://localhost:8080 \\
    -H "Content-Type: application/json" \\
    -d '{"fps":15}'  # 15 fps
```

#### Force IDR Frame
```bash
curl -X POST http://localhost:8080 \\
    -H "Content-Type: application/json" \\
    -d '{"force_idr":1}'
```

#### Combined Command
```bash
curl -X POST http://localhost:8080 \\
    -H "Content-Type: application/json" \\
    -d '{"bitrate":8000,"fps":30,"force_idr":1}'
```

#### Custom VBV Parameters
```bash
curl -X POST http://localhost:8080 \\
    -H "Content-Type: application/json" \\
    -d '{"bitrate":3000,"vbv_maxrate":3600,"vbv_bufsize":1500}'
```

## Command Reference

| Parameter | Type | Description | Default |
|-----------|------|-------------|---------|
| `bitrate` | int | Target bitrate in kbps | - |
| `vbv_maxrate` | int | VBV max bitrate in kbps | `bitrate * 1.2` |
| `vbv_bufsize` | int | VBV buffer size in kbps | `bitrate / 2` (0.5s) |
| `fps` | int | Target framerate | - |
| `force_idr` | int | Force IDR frame (0 or 1) | 0 |

## Testing

Run the provided test script:

```bash
./test_http_encoder_control.sh
```

This script:
1. Starts FFmpeg with HTTP control enabled
2. Streams to SRT (viewable in VLC)
3. Sends a sequence of control commands
4. Logs all encoder responses

## Log Output

When a command is received, you'll see detailed logs:

```
[HTTP Control] ═══ RECEIVED COMMAND ═══
[HTTP Control]   Bitrate: 5000 kbps
[HTTP Control]   FPS: 0
[HTTP Control]   Force IDR: 0
[HTTP Control] Applying bitrate config:
[HTTP Control]   i_bitrate = 5000 kbps
[HTTP Control]   i_vbv_max_bitrate = 6000 kbps
[HTTP Control]   i_vbv_buffer_size = 2500 kbps
[HTTP Control] ═══ CALLING x264_encoder_reconfig() ═══
[HTTP Control] ✓ ✓ ✓ RECONFIG SUCCESS ✓ ✓ ✓
[HTTP Control] Encoder accepted new parameters
[HTTP Control] ═══ COMMAND COMPLETE ═══
```

## How It Works

### 1. Initialization (`X264_init`)
- Creates HTTP server thread on specified port
- Registers encoder instance with the server
- Stores initial FPS for reference

### 2. Runtime Control (`X264_frame`)
- **Every frame**, checks for pending HTTP commands
- If command exists:
  - Parses bitrate, FPS, VBV settings
  - Updates `x4->params` structure
  - Calls `x264_encoder_reconfig()`
  - Logs success/failure with detailed parameters
  - Acknowledges command (clears queue)

### 3. Cleanup (`X264_close`)
- Unregisters encoder from HTTP server
- Server continues running for other encoders

## VBV Buffer Management

The implementation uses **proportional VBV buffer sizing**:

- **VBV Max Bitrate**: `target_bitrate * 1.2` (20% headroom for I-frames)
- **VBV Buffer Size**: `target_bitrate / 2` (0.5 seconds of data)

This ensures:
- Fast response to bitrate changes
- Smooth transitions without starvation
- Sufficient headroom for keyframes

## Framerate Control

FPS changes are implemented via `x264_encoder_reconfig()`:
- Updates `i_fps_num` and `i_fps_den` parameters
- x264 internally adjusts timing
- May cause frame skipping or duplication

## Comparison with SRT Rate Control

| Feature | HTTP Control | SRT Rate Control |
|---------|--------------|------------------|
| **Trigger** | External HTTP commands | Automatic (SRT stats) |
| **Control** | Manual, scriptable | Autonomous |
| **Parameters** | Bitrate, FPS, IDR | Bitrate only |
| **Use Case** | Testing, debugging | Production streaming |
| **Latency** | Immediate | 500ms intervals |

## Limitations

1. **VBV Buffer Delay**: Bitrate changes are gradual (0.5s buffer)
2. **FPS Changes**: May cause visual artifacts
3. **Single HTTP Port**: All encoders share the same HTTP server
4. **No Authentication**: HTTP server has no security

## Future Enhancements

- [ ] GOP size adjustment
- [ ] QP min/max control
- [ ] Preset/tune switching
- [ ] Real-time metrics endpoint (GET /stats)
- [ ] WebSocket support for continuous updates
- [ ] Authentication/API keys

## Files Modified

- `libavcodec/encoder_control.h` - Interface definition
- `libavcodec/encoder_control.c` - HTTP server implementation
- `libavcodec/libx264.c` - Encoder integration
- `libavcodec/Makefile` - Build configuration
- `test_http_encoder_control.sh` - Test script

## Example: Simulating Network Congestion

```bash
# Terminal 1: Start encoder
ffmpeg -re -f lavfi -i testsrc=size=1280x720:rate=30 \\
    -c:v libx264 -preset ultrafast -b:v 10000k \\
    -http_control_enable 1 -http_control_port 8080 \\
    -f mpegts "srt://localhost:9999?mode=listener"

# Terminal 2: Simulate congestion
sleep 10 && curl -X POST http://localhost:8080 \\
    -d '{"bitrate":2000}' \\
    -H "Content-Type: application/json"

# Terminal 3: Watch SRT stream
ffplay "srt://localhost:9999?mode=caller"
```

## Debugging

Enable detailed logging:

```bash
ffmpeg -loglevel info -i input.mp4 \\
    -c:v libx264 -http_control_enable 1 ...
```

Look for these log patterns:
- `[HTTP Control] Server initialized` - Server started
- `[HTTP Control] Encoder registered` - Encoder ready
- `[HTTP Control] ═══ RECEIVED COMMAND ═══` - Command received
- `[HTTP Control] ✓ ✓ ✓ RECONFIG SUCCESS ✓ ✓ ✓` - Reconfig succeeded
- `[HTTP Control] ✗ ✗ ✗ RECONFIG FAILED ✗ ✗ ✗` - Reconfig failed

## Related Features

- **SRT Rate Control**: Automatic bitrate adjustment based on SRT network stats (`-srt_rate_control 1`)
- **x264-params**: Override x264 settings via FFmpeg command line
- **libx264 API**: Direct x264 API usage for custom applications

