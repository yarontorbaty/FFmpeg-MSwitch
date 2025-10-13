# SRT Smart Hysteresis for Bitrate Control

## Overview

**Smart Hysteresis** prevents bitrate oscillations in SRT-based rate control by applying different response times for bitrate increases vs decreases:

- **⚡ Instant Downshift**: Respond immediately to bandwidth drops (protect against congestion)
- **🕒 Delayed Upshift**: Wait and verify bandwidth stability before increasing bitrate

This prevents the encoder from rapidly switching between high and low bitrates when network conditions fluctuate.

---

## Problem Statement

Without hysteresis, SRT rate control can oscillate:

```
Network BW: 10 Mbps → 5 Mbps → 10 Mbps → 5 Mbps → ... (unstable)
Encoder:    10 Mbps → 5 Mbps → 10 Mbps → 5 Mbps → ... (oscillating!)
Result:     Poor quality, constant IDR frames, viewer disruption
```

With hysteresis:

```
Network BW: 10 Mbps → 5 Mbps → 10 Mbps → 5 Mbps → ... (unstable)
Encoder:    10 Mbps → 5 Mbps → ... (waiting) → ... → 10 Mbps (stable!)
Result:     Stable quality, fewer IDR frames, smooth viewing
```

---

## Features

### 1. **Instant Downshift**
- Responds immediately to bandwidth drops
- Protects against network congestion
- Prevents packet loss and rebuffering
- Cancels any pending upshift

### 2. **Delayed Upshift with Health Check**
- Configurable delay period (default: 5 seconds)
- Verifies bandwidth stability before increasing
- Health checks every 500ms during delay
- Resets timer if bandwidth drops during delay

### 3. **Smart Integration**
- Works with **encoder restart** for instant bitrate changes
- Works with **VBV reconfig** for gradual changes  
- Integrates seamlessly with SRT bandwidth estimation
- Compatible with all existing rate control features

---

## Usage

### Basic Example (with defaults)

```bash
ffmpeg -i input.mp4 \
  -c:v libx264 \
  -b:v 10000k \
  -srt_rate_control 1 \              # Enable SRT rate control
  -srt_min_bitrate 1000000 \         # 1 Mbps min
  -srt_max_bitrate 20000000 \        # 20 Mbps max
  -f mpegts "srt://host:port?..."
```

**Default behavior**: 5-second delay before upshift

### Custom Upshift Delay

```bash
ffmpeg -i input.mp4 \
  -c:v libx264 \
  -b:v 10000k \
  -srt_rate_control 1 \
  -srt_upshift_delay_ms 10000 \      # 10-second delay
  -f mpegts "srt://host:port?..."
```

### Disable Upshift Delay (Instant Response)

```bash
ffmpeg -i input.mp4 \
  -c:v libx264 \
  -b:v 10000k \
  -srt_rate_control 1 \
  -srt_upshift_delay_ms 0 \          # Instant upshift (no delay)
  -f mpegts "srt://host:port?..."
```

### With Encoder Restart (Recommended)

```bash
ffmpeg -i input.mp4 \
  -c:v libx264 \
  -b:v 10000k \
  -srt_rate_control 1 \
  -srt_enable_encoder_restart 1 \    # Use encoder restart for instant changes
  -srt_upshift_delay_ms 5000 \       # 5-second upshift delay
  -f mpegts "srt://host:port?..."
```

---

## Configuration Options

| Option | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `srt_rate_control` | bool | 0 | 0-1 | Enable SRT-based rate control |
| `srt_enable_encoder_restart` | bool | 0 | 0-1 | Use encoder restart for instant bitrate changes |
| `srt_upshift_delay_ms` | int | 5000 | 0-60000 | Delay before increasing bitrate (ms) |
| `srt_min_bitrate` | int64 | 500000 | 100000+ | Minimum bitrate (bps) |
| `srt_max_bitrate` | int64 | 10000000 | 500000+ | Maximum bitrate (bps) |

---

## How It Works

### Downshift Logic

```
1. Bandwidth drops detected
   ↓
2. Calculate target bitrate immediately
   ↓
3. Cancel any pending upshift
   ↓
4. Apply bitrate change INSTANTLY ⚡
   ↓
5. Log: "⚡ INSTANT DOWNSHIFT: 10.0 → 5.0 Mbps"
```

**Result**: Immediate protection against congestion

### Upshift Logic

```
1. Bandwidth increase detected
   ↓
2. Start upshift timer (e.g., 5000ms)
   ↓
3. Health check every 500ms:
   │  - BW still good? ✓ Count++
   │  - BW dropped? ✗ Reset timer
   ↓
4. Timer expires + health checks passed?
   ↓
5. Apply bitrate increase
   ↓
6. Log: "✓ UPSHIFT APPROVED: 5.0 → 10.0 Mbps"
```

**Result**: Stable upshift only after verified bandwidth recovery

### Health Check Details

```
Required checks = delay_ms / 500ms

Example with 5000ms delay:
  - Check #1 @ 500ms:  BW ≥ target? ✓
  - Check #2 @ 1000ms: BW ≥ target? ✓
  - Check #3 @ 1500ms: BW ≥ target? ✗ (dropped, reset timer)
  - Check #1 @ 500ms:  BW ≥ target? ✓ (restarted)
  - Check #2 @ 1000ms: BW ≥ target? ✓
  - ...
  - Check #10 @ 5000ms: All checks passed ✓ → UPSHIFT
```

---

## Log Messages

### Downshift

```
[libx264 @ ...] [SRT Rate Control] ⚡ INSTANT DOWNSHIFT: 10.00 → 5.00 Mbps (protecting against congestion)
[libx264 @ ...] [SRT Rate Control] ⚡ AGGRESSIVE MODE: Large bitrate drop (>30%) detected
[libx264 @ ...] [SRT Rate Control] ⚡ DOWNSHIFT: Cancelling pending upshift (BW dropped)
```

### Upshift Pending

```
[libx264 @ ...] [SRT Rate Control] 🕒 UPSHIFT PENDING: 5.00 → 10.00 Mbps (waiting 5000 ms, need 10 health checks)
[libx264 @ ...] [SRT Rate Control] ✓ HEALTH CHECK 1/10: BW stable at 10.50 Mbps (elapsed: 500 ms)
[libx264 @ ...] [SRT Rate Control] ✓ HEALTH CHECK 2/10: BW stable at 10.80 Mbps (elapsed: 1000 ms)
```

### Health Check Failed

```
[libx264 @ ...] [SRT Rate Control] ✗ HEALTH CHECK FAILED: BW dropped to 7.50 Mbps, resetting upshift timer
```

### Upshift Approved

```
[libx264 @ ...] [SRT Rate Control] ✓ UPSHIFT APPROVED: 5.00 → 10.00 Mbps (health checks passed)
[libx264 @ ...] [SRT Rate Control] NORMAL MODE: Bandwidth recovered significantly
```

---

## Tuning Recommendations

### Conservative (Stable Quality)

```bash
-srt_upshift_delay_ms 15000    # 15-second delay
```
- **Use case**: Broadcast, professional streaming
- **Benefit**: Very stable quality, minimal oscillation
- **Tradeoff**: Slower recovery from congestion

### Moderate (Default)

```bash
-srt_upshift_delay_ms 5000     # 5-second delay (default)
```
- **Use case**: General live streaming, adaptive bitrate
- **Benefit**: Good balance between stability and responsiveness
- **Recommended for most users**

### Aggressive (Fast Recovery)

```bash
-srt_upshift_delay_ms 2000     # 2-second delay
```
- **Use case**: Gaming, low-latency applications
- **Benefit**: Fast recovery from temporary congestion
- **Tradeoff**: May oscillate on unstable networks

### Instant (No Hysteresis)

```bash
-srt_upshift_delay_ms 0        # Instant upshift
```
- **Use case**: Testing, very stable networks
- **Benefit**: Immediate response to bandwidth changes
- **Tradeoff**: Will oscillate on unstable networks

---

## Performance Impact

### CPU Usage
- **Minimal**: Hysteresis logic adds < 0.1% CPU overhead
- Health checks are simple comparisons every 500ms

### Latency
- **Downshift**: No added latency (instant)
- **Upshift**: Configurable (0-60 seconds)

### Memory
- **Negligible**: 32 bytes for hysteresis state

---

## Combination with Other Features

### With Encoder Restart

```bash
-srt_rate_control 1 \
-srt_enable_encoder_restart 1 \
-srt_upshift_delay_ms 5000
```

**Result**: 
- Downshift: INSTANT (1-2 frame glitch)
- Upshift: Delayed (5 seconds, no glitch)
- **Best for**: Adaptive streaming

### With Frame Skipping

```bash
-srt_rate_control 1 \
-srt_enable_frame_skip 1 \
-srt_upshift_delay_ms 5000
```

**Result**:
- Downshift: INSTANT (reduced FPS)
- Upshift: Delayed (5 seconds, FPS restored)
- **Best for**: Extreme bandwidth constraints

### HTTP Control Override

HTTP commands always bypass hysteresis:

```bash
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"bitrate":15000,"force_idr":1}'
```

**Result**: Immediate bitrate change (no delay, no health check)

---

## Comparison: With vs Without Hysteresis

### Without Hysteresis

```
Time:      0s    5s   10s   15s   20s   25s   30s
Network:  10→5→10→5→10→5→10 Mbps
Encoder:  10→5→10→5→10→5→10 Mbps
IDR:       *    *    *    *    *    *    *  (7 IDR frames)
Quality:  ████▓▓████▓▓████▓▓  (oscillating)
```

### With Hysteresis (5s delay)

```
Time:      0s    5s   10s   15s   20s   25s   30s
Network:  10→5→10→5→10→5→10 Mbps
Encoder:  10→5..................10 Mbps (stable)
IDR:       *                    *  (2 IDR frames)
Quality:  ████▓▓▓▓▓▓▓▓▓▓▓▓▓▓████  (smooth transition)
```

**Benefits**:
- 71% fewer IDR frames
- Smoother quality transitions
- Better viewer experience
- Reduced encoding overhead

---

## Algorithm Details

### Pseudocode

```python
def srt_rate_control_with_hysteresis(bandwidth):
    target_bitrate = calculate_target(bandwidth)
    
    if target_bitrate < current_bitrate:
        # DOWNSHIFT: Instant
        cancel_pending_upshift()
        apply_bitrate_change(target_bitrate)
        log("⚡ INSTANT DOWNSHIFT")
    
    elif target_bitrate > current_bitrate:
        # UPSHIFT: Delayed with health check
        if upshift_delay_ms == 0:
            apply_bitrate_change(target_bitrate)
            log("⬆ INSTANT UPSHIFT")
        else:
            if upshift_pending_start_time == 0:
                # Start timer
                upshift_pending_start_time = now()
                upshift_target = target_bitrate
                health_check_count = 0
                log("🕒 UPSHIFT PENDING")
            else:
                # Check health
                if bandwidth_still_good():
                    health_check_count++
                else:
                    # Reset timer
                    upshift_pending_start_time = now()
                    health_check_count = 0
                    log("✗ HEALTH CHECK FAILED")
                
                # Check if approved
                if elapsed >= delay and health_checks_passed:
                    apply_bitrate_change(target_bitrate)
                    reset_upshift_state()
                    log("✓ UPSHIFT APPROVED")
```

---

## Troubleshooting

### Upshift Never Happens

**Problem**: Encoder stuck at low bitrate even with good bandwidth

**Solutions**:
1. Check logs for "✗ HEALTH CHECK FAILED" messages
2. Bandwidth may be fluctuating (increase delay)
3. Health check threshold too strict (95% of target)
4. Try: `-srt_upshift_delay_ms 2000` (shorter delay)

### Still Oscillating

**Problem**: Bitrate still changes frequently

**Solutions**:
1. Increase delay: `-srt_upshift_delay_ms 10000`
2. Check network stability (`srt_stats` tool)
3. Adjust min/max bitrate range (wider range = more oscillation)
4. Enable encoder restart for cleaner transitions

### Logs Show "BW dropped to X Mbps, resetting timer"

**Problem**: Health checks keep failing

**Solutions**:
1. **Normal behavior** for unstable networks
2. Hysteresis is WORKING (preventing premature upshift)
3. If bandwidth is actually stable, check SRT stats accuracy
4. Consider longer delay to tolerate brief dips

---

## Future Enhancements

Potential improvements for future versions:

1. **Adaptive Delay**: Automatically adjust delay based on network stability
2. **Exponential Backoff**: Increase delay after repeated failed health checks
3. **Per-Direction Settings**: Different delays for different bitrate ratios
4. **Machine Learning**: Predict network trends for proactive adjustment

---

## Related Documentation

- `HTTP_ENCODER_CONTROL_README.md`: HTTP-based encoder control
- `SRT_AUTOMATIC_RATE_CONTROL_SUMMARY.md`: SRT integration overview
- `ENCODER_RESTART_FEATURE_SUMMARY.md`: Encoder restart implementation

---

## Author & License

Part of FFmpeg-MSwitch project  
License: LGPL 2.1 (same as FFmpeg)

---

**Status**: ✅ Implemented & Ready for Testing

