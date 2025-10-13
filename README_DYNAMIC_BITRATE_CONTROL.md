# FFmpeg Dynamic Bitrate Control - Complete Guide

## 🎯 **TL;DR**

This FFmpeg fork adds **instant bitrate control** for live streaming with **two proven methods**:

1. **⚡ Encoder Restart**: Instant bitrate change (1-2 frame glitch)
2. **📉 Frame Skipping**: Instant FPS reduction (no glitch, choppy)

Plus **smart features**:
- 🧠 Auto-selection based on FPS threshold
- 🕒 Smart hysteresis (instant down, delayed up)
- 🌐 HTTP REST API for manual control
- 📊 SRT bandwidth-aware automatic adaptation

---

## **Quick Start**

### **Automatic SRT Rate Control** (Recommended)

```bash
ffmpeg -i input.mp4 \
  -c:v libx264 -b:v 15000k \
  -srt_rate_control 1 \
  -enable_encoder_restart 1 \
  -srt_min_bitrate 3000000 \
  -srt_max_bitrate 25000000 \
  -srt_upshift_delay_ms 5000 \
  -f mpegts "srt://server:port?enable_stats=1"
```

**What this does**:
- Monitors SRT network stats (bandwidth, loss, RTT)
- Instantly drops bitrate when congestion detected
- Waits 5 seconds + health checks before increasing bitrate
- Prevents oscillation in unstable networks

### **Manual HTTP Control**

```bash
# Terminal 1: Start FFmpeg
ffmpeg -i input.mp4 \
  -c:v libx264 -b:v 20000k \
  -http_control_enable 1 \
  -enable_encoder_restart 1 \
  -f mpegts "srt://..."

# Terminal 2: Change bitrate at runtime
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"bitrate":8000,"force_idr":1}'
```

**Result**: Bitrate changes instantly (1-2 frames)

---

## **Configuration Options**

### **SRT Options** (Automatic Control)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `srt_rate_control` | bool | 0 | Enable SRT-based automatic rate control |
| `srt_min_bitrate` | int64 | 500000 | Minimum bitrate (bps) |
| `srt_max_bitrate` | int64 | 10000000 | Maximum bitrate (bps) |
| `srt_upshift_delay_ms` | int | 5000 | Delay before upshift (ms, 0=instant) |

### **Rate Control Methods** (Works with SRT or HTTP)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable_encoder_restart` | bool | 0 | Instant bitrate via encoder restart (1-2 frame drop) |
| `enable_frame_skip` | bool | 0 | Instant bitrate via FPS reduction (choppy) |
| `min_fps_before_restart` | int | 15 | FPS threshold: skip if FPS ≥ threshold, else restart |

### **HTTP Control** (Manual Override)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `http_control_enable` | bool | 0 | Enable HTTP REST API |
| `http_control_port` | int | 8080 | HTTP server port |

---

## **How It Works**

### **Method 1: Encoder Restart** ⚡

```
1. Bandwidth drops detected (or HTTP command received)
   ↓
2. Close current encoder: x264_encoder_close()
   ↓
3. Update bitrate params: x264_param_t.rc.i_bitrate = new_value
   ↓
4. Reopen encoder: x264_encoder_open()
   ↓
5. Continue encoding at NEW bitrate immediately
```

**Performance**:
- Bitrate change: **Instant** (first frame uses new bitrate)
- Disruption: 1-2 frames (~40-80ms gap)
- Quality: Maintains output quality at new bitrate
- FPS: Stays constant (e.g., 24fps throughout)

### **Method 2: Frame Skipping** 📉

```
1. Calculate required FPS: new_fps = current_fps × (target_bitrate / current_bitrate)
   ↓
2. If new_fps < current_fps:
   ↓
3. Set skip_interval = current_fps / new_fps
   ↓
4. Skip frames: Keep 1 out of every skip_interval frames
   ↓
5. Effective bitrate drops proportionally
```

**Performance**:
- Bitrate change: **Instant** (immediate frame dropping)
- Disruption: None (no encoder restart)
- Quality: Same quality per frame
- FPS: Reduced (e.g., 24fps → 12fps → choppy)

### **Smart Hysteresis** 🧠

```
DOWNSHIFT (Bandwidth Drops):
   • Detected immediately
   • Applied INSTANTLY ⚡
   • Protects against congestion
   • Cancels any pending upshift

UPSHIFT (Bandwidth Improves):
   • Start timer (default 5 seconds)
   • Health check every 500ms
   • Verify BW ≥ 95% of target
   • If BW drops: Reset timer
   • If delay expires + checks pass: Apply ✓
```

**Benefits**:
- Prevents rapid oscillation
- Stable quality for viewers
- Fewer IDR frames (better compression)
- Adapts to actual network stability

### **Hybrid Mode** (Both Methods Enabled)

```
if (calculated_fps < min_fps_before_restart):
    USE ENCODER RESTART    # FPS too low, restart needed
else:
    USE FRAME SKIPPING     # FPS acceptable, skip frames
```

**Example** (24fps → target 6 Mbps):
- If target requires 8fps: Use restart (8 < 15 threshold)
- If target requires 18fps: Use frame skip (18 ≥ 15 threshold)

---

## **Supported Codecs**

| Codec | Encoder Restart | Frame Skip | HTTP Control | SRT Integration |
|-------|----------------|------------|--------------|-----------------|
| **libx264** (H.264) | ✅ | ✅ | ✅ | ✅ |
| **libx265** (HEVC) | ✅ | ❌ | ✅ | ❌ |

*Note: libx265 currently supports encoder restart only (frame skip not yet implemented)*

---

## **Performance Comparison**

| Method | Bitrate Response | Frame Disruption | FPS Impact | Use Case |
|--------|-----------------|------------------|------------|----------|
| **Encoder Restart** | Instant | 1-2 frames | None | General streaming |
| **Frame Skip** | Instant | None | Reduced FPS | Extreme congestion |
| **Hybrid** | Instant | Varies | Smart | Production (recommended) |

---

## **Testing**

### **Local Test (HTTP Control)**

```bash
./test_http_encoder_control.sh
```

### **Docker Test (SRT + netem)**

```bash
./test_srt_hysteresis_docker.sh
```

### **libx265 Test**

```bash
./test_http_encoder_control_x265.sh
```

---

## **HTTP API Reference**

### **Change Bitrate**

```bash
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"bitrate":8000,"force_idr":1}'
```

### **Force IDR Frame**

```bash
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"force_idr":1}'
```

### **Response**

```json
{"status":"ok"}
```

---

## **Documentation Index**

- **HTTP_ENCODER_CONTROL_README.md**: HTTP control detailed guide
- **HTTP_COMMANDS.md**: Quick command reference
- **SRT_SMART_HYSTERESIS_README.md**: Hysteresis logic explained
- **CORRECTED_OPTIONS_GUIDE.md**: Complete option reference
- **ENCODER_RESTART_FEATURE_SUMMARY.md**: Technical implementation details
- **FINAL_FEATURE_SUMMARY.md**: Comprehensive feature overview

---

## **Troubleshooting**

### **Q: Bitrate not changing?**

**A**: Enable a rate control method:
```bash
-enable_encoder_restart 1    # OR
-enable_frame_skip 1
```

### **Q: Playback is choppy?**

**A**: You're using frame skipping. Switch to encoder restart:
```bash
-enable_encoder_restart 1
# Remove: -enable_frame_skip 1
```

### **Q: Brief visual glitch when bitrate changes?**

**A**: This is expected with encoder restart (1-2 frames). Options:
- Accept the glitch (recommended, barely noticeable)
- Use frame skip instead (no glitch, but choppy)
- Use longer upshift delay to reduce frequency

### **Q: Bitrate oscillating rapidly?**

**A**: Increase upshift delay:
```bash
-srt_upshift_delay_ms 10000    # 10 seconds
```

---

## **Build Instructions**

### **Local Build**

```bash
./configure \
  --enable-gpl \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libsrt

make -j$(nproc)
```

### **Docker Build**

```bash
docker build -t ffmpeg-dynamic-bitrate:latest .
```

---

## **Repository**

- **GitHub**: https://github.com/yarontorbaty/FFmpeg-MSwitch
- **Branch**: feature/enhanced-srt-integration
- **License**: LGPL 2.1+ (same as FFmpeg)

---

## **Version History**

### **v1.0** (2025-10-13)
- ✅ HTTP control server
- ✅ Encoder restart (libx264 + libx265)
- ✅ Frame skipping (libx264)
- ✅ Smart hysteresis
- ✅ SRT integration
- ✅ Predictive bandwidth measurement
- ✅ Simplified, production-ready code

---

## **Credits**

Developed through extensive testing and iteration:
- Tested with Docker + `netem` for realistic network simulation
- Validated with VLC for real-time visual quality assessment
- Benchmarked against "Big Buck Bunny" 720p test content
- Iterative refinement based on actual bitrate measurements

**Result**: A production-ready solution for instant bitrate adaptation in live streaming.

---

**Status**: ✅ **Production Ready** | **Last Updated**: 2025-10-13

