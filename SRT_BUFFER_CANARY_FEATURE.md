# SRT Buffer Canary Detection

## 🐦 Overview

The **Buffer Canary** feature provides **sub-second bandwidth drop detection** for SRT streaming by monitoring the send buffer fill level. This is significantly faster than traditional bandwidth estimation (which takes 3-5 seconds).

## How It Works

### Traditional Bandwidth Detection (OLD)
```
Time 0s:  Bandwidth drops to 10 Mbps
Time 3s:  SRT latency buffer fills up
Time 5s:  Bandwidth estimation detects drop
Time 5s:  Encoder restart triggered
```
**Detection Latency: ~5 seconds** ❌

### Buffer Canary Detection (NEW)
```
Time 0s:  Bandwidth drops to 10 Mbps
Time 0.5s: Send buffer starts filling (msSndBuf increases)
Time 1s:  Buffer > 75% of latency threshold
Time 1s:  🐦 CANARY TRIGGERED - Instant encoder restart!
```
**Detection Latency: <1 second** ✅

## Technical Details

### SRT Metric Used
- **`msSndBuf`**: Milliseconds of data currently in the send buffer
- This metric rises **immediately** when available bandwidth drops below send rate
- Provides **instant feedback** without waiting for packet loss or RTT increases

### Thresholds

With default 3000ms SRT latency:

| Buffer Level | Threshold | Action |
|--------------|-----------|--------|
| < 1500ms | - | Normal operation |
| 1500-2250ms | Warning | Log warning message |
| > 2250ms | **Critical** | **Instant 40% bitrate reduction** |

The thresholds scale with SRT latency:
- **Warning:** 50% of `srt_latency`
- **Critical:** 75% of `srt_latency`

### Integration with Existing Logic

The canary works **in conjunction** with bandwidth-based rate control:

1. **Canary triggers** when buffer fills → Force immediate downshift
2. **Bandwidth estimation** provides fine-tuned adjustments → Optimize long-term bitrate
3. **Smart hysteresis** prevents oscillations → Delayed upshifts with health checks

## Configuration Options

### New Parameters

| Option | Default | Description |
|--------|---------|-------------|
| `-srt_latency` | 3000 | SRT latency in ms (sets canary thresholds) |
| `-srt_bitrate_change_threshold` | 30 | Minimum % change to trigger adjustment |

### Example Usage

```bash
ffmpeg -i input.mp4 \
    -c:v libx264 \
    -srt_rate_control 1 \
    -srt_latency 3000 \
    -srt_bitrate_change_threshold 30 \
    -srt_min_bitrate 3000000 \
    -srt_max_bitrate 25000000 \
    -enable_encoder_restart 1 \
    -srt_upshift_delay_ms 5000 \
    -f mpegts "srt://0.0.0.0:4200?mode=listener&latency=3000&enable_stats=1"
```

## Log Messages

### Normal Operation
```
[srt] SRT Stats: BW=20.00 Mbps, Loss=0.10%, RTT=50.0 ms, BufMs=150
```

### Canary Warning
```
[libx264] 🐦 CANARY WARNING: Buffer rising (1600 ms / 3000 ms latency)
```

### Canary Critical (Instant Action)
```
[libx264] 🐦 CANARY CRITICAL: Buffer filling (2400 ms / 3000 ms latency)! Bandwidth drop detected!
[libx264] 🐦 CANARY ACTION: Overriding BW target (15.0 → 9.0 Mbps)
[libx264] ⚡ INSTANT DOWNSHIFT: 15.00 → 9.00 Mbps (protecting against congestion)
[libx264] ═══ ENCODER RESTART ═══
[libx264] ✓ RESTARTED: 15.00 → 9.00 Mbps
```

### Threshold Filtering
```
[libx264] Ignoring small change: 10.00 → 10.20 Mbps (2.0% < 30% threshold)
```

## Performance Characteristics

### Detection Speed
- **Buffer canary:** <1 second (0.5-1.0s typical)
- **Bandwidth estimation:** 3-5 seconds
- **Combined system:** Best of both (fast + accurate)

### Restart Frequency Control

Multiple layers prevent excessive restarts:

1. **30% minimum threshold** - Only significant changes trigger action
2. **5-second rate limiting** - Max 1 restart per 5 seconds
3. **Duplicate prevention** - Same bitrate won't restart twice
4. **Smart hysteresis** - Upshifts delayed for stability verification

### Example: 25 Mbps → 10 Mbps Drop

**Without Canary:**
```
Time 0s:  dnctl applied
Time 5s:  Bandwidth detected, encoder restarts to 8 Mbps
Result: 5 seconds of congestion artifacts
```

**With Canary:**
```
Time 0s:  dnctl applied
Time 0.8s: Buffer canary detects, encoder restarts to 15 Mbps (40% reduction)
Time 6s:  Bandwidth estimation fine-tunes to 8 Mbps (after 5s rate limit)
Result: <1 second of congestion, smooth transition
```

## Testing

### Test Script
```bash
./test_srt_docker_demo.sh
```

### Manual Bandwidth Control

Apply bandwidth limits using `dnctl`:

```bash
# Phase 1: Baseline (no limit)
# Just observe initial bitrate (~18-20 Mbps)

# Phase 2: Moderate congestion (should trigger canary)
sudo dnctl pipe 1 config bw 10Mbit/s delay 50ms plr 0.01
sudo pfctl -f - <<EOF
dummynet out proto udp from any to any port 4200 pipe 1
dummynet in proto udp from any port 4200 to any pipe 1
EOF
sudo pfctl -e

# Expected: Canary triggers within 1 second, bitrate drops to ~12-15 Mbps

# Phase 3: Recovery
sudo dnctl pipe 1 config bw 18Mbit/s delay 30ms plr 0.005

# Expected: After 5 second delay + health checks, bitrate increases to ~14-16 Mbps

# Phase 4: Remove limits
sudo pfctl -f /etc/pf.conf
sudo pfctl -e
sudo dnctl -q flush

# Expected: After 5 second delay, bitrate returns to ~20-25 Mbps
```

### What to Look For

**Canary Messages:**
- `🐦 CANARY WARNING` - Buffer starting to fill
- `🐦 CANARY CRITICAL` - Instant action triggered
- `🐦 CANARY ACTION` - Overriding bandwidth target

**Improved Behavior:**
- No more `3.00 → 3.02 Mbps` tiny upshifts
- Encoder restarts only for 30%+ changes
- Detection within 1 second of applying `dnctl` rules

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  SRT Monitoring (libavformat/libsrt.c)                  │
│  ┌────────────────────────────────────────────────┐    │
│  │ Every packet send:                              │    │
│  │   srt_bstats() → perf.msSndBuf                 │    │
│  │   stats.send_buffer_ms = perf.msSndBuf         │    │
│  └────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
                          ↓ (500ms polling)
┌─────────────────────────────────────────────────────────┐
│  Encoder (libavcodec/libx264.c)                         │
│  ┌────────────────────────────────────────────────┐    │
│  │ Every 500ms:                                    │    │
│  │   1. Check send_buffer_ms                      │    │
│  │      if > 75% latency → INSTANT DOWNSHIFT      │    │
│  │                                                  │    │
│  │   2. Calculate BW-based target bitrate         │    │
│  │      Apply loss/RTT penalties                  │    │
│  │                                                  │    │
│  │   3. Check minimum threshold (30%)             │    │
│  │      if change < 30% → SKIP                    │    │
│  │                                                  │    │
│  │   4. Apply smart hysteresis                    │    │
│  │      Downshift: Instant (if > threshold)       │    │
│  │      Upshift: Delayed + health checks          │    │
│  │                                                  │    │
│  │   5. Rate limiting (max 1 restart / 5s)        │    │
│  └────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

## Improvements Over Previous Version

| Feature | Before | After |
|---------|--------|-------|
| **Detection Speed** | 5 seconds | <1 second |
| **Minimum Change** | 10% or 2 Mbps | 30% (configurable) |
| **Duplicate Restarts** | Yes (frequent) | No (prevented) |
| **Tiny Upshifts** | Yes (3.00→3.02) | No (filtered) |
| **Rate Limiting** | 5 seconds | 5 seconds ✓ |
| **RTT Thresholds** | 100ms | 150ms (less aggressive) |

## Code Changes

### Modified Files
1. `libavformat/srt_bandwidth.h` - Added `send_buffer_ms` field
2. `libavformat/srt_bandwidth.c` - Populated from `perf.msSndBuf`
3. `libavformat/libsrt.c` - Updated logging to show buffer
4. `libavcodec/libx264.c` - Implemented canary detection + configurable threshold
5. `test_srt_docker_demo.sh` - Updated with new parameters

### New Options
- `-srt_latency <ms>` - Controls canary thresholds
- `-srt_bitrate_change_threshold <percent>` - Controls minimum change (default 30%)

## Expected Results

With 30% threshold:
- **At 25 Mbps:** Changes >7.5 Mbps trigger action
- **At 10 Mbps:** Changes >3 Mbps trigger action  
- **At 3 Mbps:** Changes >0.9 Mbps trigger action

This eliminates noise while preserving responsiveness to real bandwidth changes.

