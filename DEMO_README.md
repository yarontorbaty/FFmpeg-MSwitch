# SRT Rate Control Demo

## Overview
This demo showcases FFmpeg's built-in SRT-aware dynamic bitrate control for libx264. The encoder automatically adjusts its bitrate in real-time based on network conditions (bandwidth, packet loss, RTT).

## Features

### 1. **Dynamic Bitrate Adjustment**
- Real-time monitoring of SRT network statistics
- Automatic encoder reconfiguration using `x264_encoder_reconfig()`
- Bitrate adapts to: bandwidth availability, packet loss, and round-trip time (RTT)

### 2. **Visual Demo Components**
- **VLC Playback**: Watch quality changes in real-time
- **On-Screen Overlay**: Shows current network phase and target bitrate
- **Real-Time Graph**: Matplotlib plot of actual vs. target bitrate

### 3. **Test Phases** (60 seconds total)
- **Phase 1 (0-15s)**: Excellent network (10 Mbps) → Target: ~5 Mbps
- **Phase 2 (15-30s)**: Moderate (3 Mbps + 2% loss) → Target: ~1.5 Mbps  
- **Phase 3 (30-45s)**: Severe (1 Mbps + 10% loss) → Target: 0.5 Mbps
- **Phase 4 (45-60s)**: Recovery (8 Mbps) → Target: ~4 Mbps

## Running the Demo

### Quick Test (No Plot)
```bash
./test_srt_rate_control.sh
```
- Opens VLC
- Shows video with on-screen overlay
- Logs bitrate changes to console

### Full Demo (With Real-Time Plot)
```bash
./test_srt_demo_with_plot.sh
```
- Opens VLC for playback
- Opens real-time bitrate graph
- Shows phase-colored overlay on video
- Best for recording demo videos

## What to Observe

### In VLC
- **Quality Changes**: Video clarity degrades during phases 2-3, recovers in phase 4
- **On-Screen Text**: Color-coded phase indicators
  - Green = Excellent network
  - Orange = Moderate congestion
  - Red = Severe congestion
  - Blue = Recovery

### In the Graph (Full Demo)
- **Blue Line**: Actual encoder bitrate
- **Red Dashed Line**: Target bitrate from rate control
- **Background Color**: Changes with phase
- Watch the lines converge as encoder adapts

### In Console Logs
Look for `[SRT Rate Control]` messages showing:
```
[SRT Rate Control] BW=2.26 Mbps, Loss=2.28%, RTT=70.3 ms → Bitrate: 500000 → 1263360 bps (1.26 Mbps)
```

## Technical Details

### Encoder Options Added
- `-srt_rate_control 1` - Enable SRT-aware rate control
- `-srt_min_bitrate 500000` - Minimum bitrate (0.5 Mbps)
- `-srt_max_bitrate 5000000` - Maximum bitrate (5 Mbps)

### How It Works
1. **Global Stats Sharing**: `libavformat/libsrt.c` exports network stats globally
2. **Encoder Integration**: `libavcodec/libx264.c` reads stats every second
3. **Bitrate Calculation**: Based on bandwidth, loss, and RTT
4. **Reconfiguration**: Calls `x264_encoder_reconfig()` with new parameters
5. **VBV Update**: Adjusts buffer size to match new bitrate

### Rate Control Algorithm
```c
target_bitrate = bandwidth * 0.8;  // 80% of available bandwidth

// Reduce for packet loss
if (loss > 5%) target *= 0.5;      // Severe
else if (loss > 2%) target *= 0.7; // High
else if (loss > 0.5%) target *= 0.85; // Moderate

// Reduce for high RTT (congestion indicator)
if (rtt > 200ms) target *= 0.6;
else if (rtt > 100ms) target *= 0.8;

// Clamp to configured min/max
target = clamp(target, min_bitrate, max_bitrate);

// Only update if change > 10% (stability)
if (abs(target - current) > current * 0.1) {
    x264_encoder_reconfig(encoder, &new_params);
}
```

## Recording the Demo

### Using macOS Screen Recording
1. Press `Cmd+Shift+5` to open screen recording
2. Select "Record Selected Portion"
3. Position to capture both VLC and the graph
4. Run: `./test_srt_demo_with_plot.sh`
5. Stop recording after 60 seconds

### Tips for Best Demo Video
- Increase VLC window size for better visibility
- Position VLC and graph side-by-side
- Use full-screen mode in VLC for cleaner recording
- The overlay text is large and clearly visible

## Files Modified

### Core Implementation
- `libavformat/libsrt.c` - Global SRT stats export
- `libavformat/srt_bandwidth.h` - Stats API declaration
- `libavcodec/libx264.c` - Rate control integration

### Test Infrastructure  
- `Dockerfile.ffmpeg-srt-x264tcp` - Build environment
- `test_srt_rate_control.sh` - Basic test with overlay
- `test_srt_demo_with_plot.sh` - Full demo with plotting
- `plot_bitrate.py` - Real-time matplotlib visualization

## Troubleshooting

### VLC Not Opening
- Check if VLC is installed: `/Applications/VLC.app/Contents/MacOS/VLC`
- Port 5400 might be in use: Change `VLC_PORT` in script

### Graph Not Appearing
- Ensure matplotlib is installed: `pip3 install matplotlib`
- Check for Python errors in console output

### No Quality Change Visible
- Check console for `[SRT Rate Control]` messages
- Verify network simulation is active: `tc qdisc show dev lo` (in Docker)
- Increase test duration if phases are too short

### Artifacts During Low Bitrate
- This is expected! Shows encoder is responding to bad network
- Increase `-bufsize` or SRT `latency` to reduce artifacts
- Current settings balance visibility of quality change vs. smoothness

## Next Steps
- Test with real SRT receivers (not just local loopback)
- Add support for libx265 rate control
- Implement more sophisticated rate adaptation (e.g., GCC algorithm)
- Add metrics logging for automated testing

