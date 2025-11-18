# FFmpeg-MSwitch v1.4.0

Multi-source video switching with seamless failover + SRT adaptive bitrate streaming for FFmpeg.

## 🎯 What's Included

- **FFmpeg** with mswitchdirect demuxer (cross-platform)
- **SRT adaptive bitrate streaming** with sub-100ms congestion detection
- **CLI keyboard controls** (macOS/Linux) + **HTTP API** (all platforms)
- **SRT relay server** for multi-client support
- **Real-time monitoring tools** with bandwidth visualization
- Full documentation and examples

## ✨ Features

### MSwitch Direct Demuxer
- ✅ **Multi-source failover** - Automatic and manual switching between video sources
- ✅ **Sub-second auto-failover** - <600ms failover latency (imperceptible to viewers)
- ✅ **Clean cutover** - Smooth transitions with decoder flush and I-frame sync
- ✅ **Smart timeout** - 1000ms default prevents false positives from encoding lag
- ✅ **Freeze-frame** - Repeats last frame during source loss
- ✅ **HTTP API** - Control switching via REST API on port 8099
- ✅ **CLI keyboard** - Press 1/2/3 to switch, s for status (Unix only)

### SRT Adaptive Bitrate
- ✅ **Automatic bitrate adjustment** - Real-time encoder adaptation based on SRT network stats
- ✅ **Buffer canary system** - Sub-100ms congestion detection (50ms warning, 100ms critical)
- ✅ **Instant downshifts** - Immediate 20-50% bitrate reduction on congestion
- ✅ **Gradual upshifts** - Conservative increases with health checks to prevent oscillation
- ✅ **Enhanced libsrt integration** - Per-second unrecovered packet metrics
- ✅ **Real-time visualization** - Bandwidth plotting with sender/receiver comparison
- ✅ **Both H.264 and HEVC** - Works with libx264 and libx265

### Core Features
- ✅ **H.264** (libx264), **HEVC** (libx265), **AV1** (libaom-av1)
- ✅ **SRT protocol** with enhanced statistics and monitoring
- ✅ **All standard filters** - drawtext, drawbox, overlay, scale, crop, etc.
- ✅ **SRT relay server** with clean signal handling
- ✅ **Optimized builds** - Release configuration for all platforms

## 🖥️ Platform Support

### macOS (arm64 - Apple Silicon)
- **Architecture:** M1/M2/M3/M4
- **Requires:** macOS 11.0 (Big Sur) or later
- **Controls:** CLI keyboard + HTTP API
- **File:** `ffmpeg-mswitch-macos-arm64-v1.4.0.tar.gz`

### macOS (x86_64 - Intel)
- **Architecture:** Intel 64-bit
- **Requires:** macOS 10.13 or later
- **Controls:** CLI keyboard + HTTP API
- **File:** `ffmpeg-mswitch-macos-x86_64-v1.4.0.tar.gz`

### Linux (x86_64)
- **Architecture:** x86_64
- **Requires:** glibc 2.31+
- **Controls:** CLI keyboard + HTTP API
- **File:** `ffmpeg-mswitch-linux-x86_64-v1.4.0.tar.gz`

### Windows (x86_64)
- **Architecture:** x86_64
- **Requires:** Windows 10 or later
- **Controls:** HTTP API only
- **File:** `ffmpeg-mswitch-windows-x86_64-v1.4.0.zip`

## 🆕 What's New in v1.4.0

### 🎯 Sub-Second Auto-Failover
- **Fixed critical blocking bug** - Auto-failover now triggers reliably within 600ms
- **Smart timeout system** - 1000ms default prevents false positives from encoding lag
- **No more disconnections** - SRT sources stay connected after automatic failover
- **Production-ready** - Tested and verified with smooth, imperceptible transitions

### 🔧 Technical Improvements
- Added 50ms timeout to `packet_buffer_get` to prevent indefinite blocking
- Fixed grace period misapplication in auto-failover path
- Optimized health check timing for sub-second response
- Enhanced SRT source stability during failover events

### 🐛 Bug Fixes
- **Issue #5**: SRT sources no longer disconnect after automatic failover
- Fixed `read_packet` blocking forever when active source dies
- Eliminated false positives from momentary encoding lag
- Corrected `last_packet_time` reset during failover

### 📦 Previous Updates (v1.3.0)
- **Windows PowerShell support** - Runtime DLLs now included (#4)
- **Windows compatibility** - MSwitch Direct works on Windows 10+
- **Enhanced monitoring** - Real-time bandwidth visualization
- **Complete documentation** - All SRT options documented for libx264 and libx265

---

## 📦 Installation

### macOS / Linux
```bash
# Download and extract
tar -xzf ffmpeg-mswitch-*.tar.gz
cd ffmpeg-mswitch-*/

# Test
./ffmpeg -version
./ffmpeg -formats | grep mswitchdirect
```

### Windows
```powershell
# Extract the ZIP file
Expand-Archive ffmpeg-mswitch-windows-x86_64-v1.4.0.zip

# Test
.\ffmpeg.exe -version
.\ffmpeg.exe -formats | findstr mswitchdirect
```

## 🚀 Quick Start

### Basic Multi-Source Failover (UDP)

```bash
# Start 3 video sources
ffmpeg -re -i video1.mp4 -c:v libx264 -f mpegts udp://127.0.0.1:12350 &
ffmpeg -re -i video2.mp4 -c:v libx264 -f mpegts udp://127.0.0.1:12351 &
ffmpeg -re -i video3.mp4 -c:v libx264 -f mpegts udp://127.0.0.1:12352 &

# Start mswitchdirect with auto-failover
./ffmpeg -f mswitchdirect \
  -msw_sources "udp://127.0.0.1:12350,udp://127.0.0.1:12351,udp://127.0.0.1:12352" \
  -msw_port 8099 \
  -msw_auto_failover 1 \
  -i dummy \
  -c:v libx264 -f mpegts udp://output:5000
```

### Control Methods

#### HTTP API (All Platforms)
```bash
# Switch to source 1
curl http://localhost:8099/switch?source=1

# Get current status
curl http://localhost:8099/status
```

#### CLI Keyboard (macOS/Linux only)
While ffmpeg is running:
- Press **`1`** to switch to source 0
- Press **`2`** to switch to source 1
- Press **`3`** to switch to source 2
- Press **`s`** to show status
- Press **`q`** to quit

**Note:** Windows users should use the HTTP API instead.

### With SRT Sources

```bash
# Option 1: Direct connection (if sources support multiple clients)
./ffmpeg -f mswitchdirect \
  -msw_sources "srt://source1:9000?mode=caller,srt://source2:9000?mode=caller" \
  -msw_port 8099 -msw_auto_failover 1 \
  -i dummy -c:v libx264 -f mpegts udp://output:5000

# Option 2: With SRT relay (recommended for FFmpeg sources)
# See tools/srt_relay/README.md for setup instructions
```

### SRT Adaptive Bitrate Streaming

```bash
# Basic SRT output with auto bitrate adjustment
./ffmpeg -re -i input.mp4 \
  -c:v libx264 -preset ultrafast \
  -enable_encoder_restart 1 \
  -srt_rate_control 1 \
  -srt_min_bitrate 3000000 \
  -srt_max_bitrate 25000000 \
  -f mpegts "srt://receiver:4200?mode=listener&latency=3000"
```

**How it works:**
- Monitors SRT bandwidth, loss, RTT, and send buffer in real-time
- **Downshifts instantly** when congestion detected (buffer canary: 50ms warning, 100ms critical)
- **Upshifts gradually** after sustained improvement (configurable delay + health checks)
- **Prevents oscillation** with 30% change threshold (configurable)

See README.md for full configuration options and examples.

## 📋 Key Options

| Option | Description | Default |
|--------|-------------|---------|
| `-msw_sources` | Comma-separated source URLs | Required |
| `-msw_port` | HTTP API port | 8099 |
| `-msw_auto_failover` | Enable auto-failover | 1 (on) |
| `-msw_clean_switch` | Enable clean cutover | 0 (off) |
| `-msw_health_interval` | Health check interval (ms) | 50 |
| `-msw_source_timeout` | Source timeout (ms) | 300 |
| `-msw_reconnect_timeout` | Reconnection timeout (ms, 0=infinite) | 0 |

## 🆕 What's New in v1.3.0

### Windows Support for MSwitch Direct
- 🚀 **Full Windows compatibility** - mswitchdirect demuxer now works on Windows
- 🚀 **Cross-platform threading** - Refactored to use FFmpeg's threading abstraction (AVMutex/AVCond)
- 🚀 **Windows testing CI/CD** - Automated GitHub Actions workflow with binary artifacts
- 🚀 **All platforms supported** - macOS (Intel/ARM), Linux, and Windows

### Previous Features (from v1.2)

#### SRT Adaptive Bitrate Streaming
- 🚀 **Enhanced libsrt integration** - Real-time network statistics monitoring
- 🚀 **Automatic encoder bitrate adjustment** - Adapts to bandwidth changes instantly
- 🚀 **Buffer canary system** - Sub-100ms congestion detection
  - Warning threshold (50ms): 20% immediate bitrate reduction
  - Critical threshold (100ms): 50% immediate bitrate reduction
- 🚀 **Intelligent upshift strategy** - Gradual increases with health checks to prevent oscillation
- 🚀 **Per-second packet metrics** - Delta-based unrecovered packet percentage (not cumulative)
- 🚀 **Dual encoder support** - Works with both libx264 (H.264) and libx265 (HEVC)

#### Monitoring & Debugging Tools
- 📊 **Real-time bandwidth plotting** - Visualize SRT bandwidth vs receiver throughput
- 📊 **ffplay integration** - Accurate receiver-side measurements
- 📊 **Interactive demo script** - 4-phase bandwidth test with visual overlay
- 📊 **Comprehensive logging** - Per-second SRT stats with bandwidth, loss, RTT, buffer fill time

#### Configuration Options
- ⚙️ **Configurable thresholds** - Control sensitivity and stability
- ⚙️ **Bitrate range** - Set min/max bitrate bounds (500kbps - 50Mbps)
- ⚙️ **Upshift delay** - Prevent premature increases (default 5s)
- ⚙️ **Health checks** - Require sustained improvement before upshift (default 10 checks)
- ⚙️ **Change threshold** - Minimum bandwidth change to trigger adjustment (default 30%)
- ⚙️ **Encoder restart** - Instant bitrate changes with 1-2 frame drop
- ⚙️ **Frame skip** - Alternative bitrate reduction via FPS adjustment

#### HTTP Control & Integration
- 🎛️ **HTTP encoder control** - Manual bitrate adjustment via REST API (port 8081)
- 🎛️ **Hybrid mode** - Combine SRT auto-adjustment with HTTP overrides
- 🎛️ **HTTP-only mode** - Disable SRT auto-adjustment for full manual control
- 🎛️ **MSwitch HTTP API** - Source switching and status monitoring (port 8080)

#### Performance Improvements
- ⚡ **50-100ms response time** - Down from 5-10 seconds with buffer canary
- ⚡ **5-second warmup** - Ignores fake initial bandwidth stats
- ⚡ **Eliminates overshoot** - No more 10+ second bitrate spikes during transitions
- ⚡ **Accurate packet loss** - Per-second metrics prevent cumulative errors

#### Documentation
- 📚 **Comprehensive README** - Full SRT auto bitrate adjustment guide
- 📚 **Configuration presets** - Examples for stable, unstable, and low-latency connections
- 📚 **Troubleshooting guide** - Common issues and solutions
- 📚 **Monitoring tips** - How to interpret SRT stats and metrics

## 🔧 Troubleshooting

### macOS: "Cannot verify developer"
```bash
xattr -d com.apple.quarantine ffmpeg
xattr -d com.apple.quarantine ffprobe
xattr -d com.apple.quarantine ffplay
```

### Windows: CLI keyboard not working
This is expected. Use the HTTP API instead:
```powershell
# Switch source
Invoke-WebRequest -Uri "http://localhost:8099/switch?source=1"

# Get status
Invoke-WebRequest -Uri "http://localhost:8099/status"
```

### SRT Connection Issues
- Try direct connection first
- If experiencing disconnections, use the SRT relay
- See `SRT_RELAY_README.md` in the package

### Verbose Logging
```bash
# Enable debug logging if needed
./ffmpeg -v debug -f mswitchdirect ...
```

## 📚 Documentation

- **Full Guide:** [README.md](https://github.com/yarontorbaty/FFmpeg-MSwitch)
- **SRT Setup:** See `SRT_RELAY_README.md` in the package
- **Examples:** Multiple codec and protocol examples in main README

## 🐛 Known Limitations

- **Windows CLI:** Keyboard commands not supported (use HTTP API)
- **SRT Sources:** If using FFmpeg as SRT source, use the included SRT relay
- **Codec Performance:** HEVC and AV1 encoding require more CPU than H.264

## 💬 Support

- **Issues:** [GitHub Issues](https://github.com/yarontorbaty/FFmpeg-MSwitch/issues)
- **Documentation:** [README.md](https://github.com/yarontorbaty/FFmpeg-MSwitch)
- **Original FFmpeg:** [ffmpeg.org](https://ffmpeg.org)

## 📄 License

FFmpeg-MSwitch is licensed under **LGPL v3** (same as FFmpeg).

See `LICENSE.md` in the package for full license text.

## 🙏 Credits

- Based on [FFmpeg](https://ffmpeg.org)
- SRT protocol by [SRT Alliance](https://www.srtalliance.org)
- Developed by Yaron Torbaty

---

**Download:** [GitHub Releases](https://github.com/yarontorbaty/FFmpeg-MSwitch/releases/tag/v1.4.0)

**Verify checksums:** Each package includes a `.sha256` file for verification.