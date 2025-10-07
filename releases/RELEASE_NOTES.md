# FFmpeg-MSwitch v1.0.1

Multi-source video switching with seamless failover for FFmpeg.

## 🎯 What's Included

- **FFmpeg** with mswitchdirect demuxer (cross-platform)
- **CLI keyboard controls** (macOS/Linux) + **HTTP API** (all platforms)
- **SRT relay server** for multi-client support
- **Helper scripts** for easy SRT setup
- Full documentation and examples

## ✨ Features

- ✅ **Multi-source failover** - Automatic and manual switching between video sources
- ✅ **Clean cutover** - Smooth transitions with decoder flush and I-frame sync
- ✅ **Auto-failover** - Immediate switch when source becomes unhealthy
- ✅ **Freeze-frame** - Repeats last frame during source loss
- ✅ **HTTP API** - Control switching via REST API on port 8099
- ✅ **CLI keyboard** - Press 1/2/3 to switch, s for status (Unix only)
- ✅ **H.264** (libx264), **HEVC** (libx265), **AV1** (libaom-av1)
- ✅ **SRT protocol** with improved error handling
- ✅ **All standard filters** - drawtext, drawbox, overlay, scale, crop, etc.
- ✅ **SRT relay server** with clean signal handling
- ✅ **Optimized builds** - Release configuration for all platforms

## 🖥️ Platform Support

### macOS (arm64 - Apple Silicon)
- **Architecture:** M1/M2/M3/M4
- **Requires:** macOS 11.0 (Big Sur) or later
- **Controls:** CLI keyboard + HTTP API
- **File:** `ffmpeg-mswitch-macos-arm64-v1.0.1.tar.gz`

### macOS (x86_64 - Intel)
- **Architecture:** Intel 64-bit
- **Requires:** macOS 10.13 or later
- **Controls:** CLI keyboard + HTTP API
- **File:** `ffmpeg-mswitch-macos-x86_64-v1.0.1.tar.gz`

### Linux (x86_64)
- **Architecture:** x86_64
- **Requires:** glibc 2.31+
- **Controls:** CLI keyboard + HTTP API
- **File:** `ffmpeg-mswitch-linux-x86_64-v1.0.1.tar.gz`

### Windows (x86_64)
- **Architecture:** x86_64
- **Requires:** Windows 10 or later
- **Controls:** HTTP API only
- **File:** `ffmpeg-mswitch-windows-x86_64-v1.0.1.zip`

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
Expand-Archive ffmpeg-mswitch-windows-x86_64-v1.0.1.zip

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

## 🆕 What's New in v1.0.1

### Fixes
- ✅ **CLI keyboard commands restored** on macOS/Linux
- ✅ **Windows build fixes** - proper cross-platform compilation
- ✅ **GitHub Actions packaging** - uses native environment variables
- ✅ **Cross-platform srt_relay** - builds on all platforms

### Improvements
- 🔧 Platform-specific CLI handling (stubs on Windows with helpful messages)
- 🔧 PowerShell-based packaging for Windows (native Compress-Archive)
- 🔧 Cross-platform Makefile for srt_relay (pthread on Unix, ws2_32 on Windows)
- 🔧 Cleaner build system without git dependencies in CI

### Codebase Cleanup
- 🧹 Removed 900+ lines of experimental code
- 🧹 Deleted old `mswitch` demuxer (subprocess-based)
- 🧹 Removed Unix-only experimental features
- 🧹 Production-ready, maintainable codebase

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

**Download:** [GitHub Releases](https://github.com/yarontorbaty/FFmpeg-MSwitch/releases/tag/v1.0.1)

**Verify checksums:** Each package includes a `.sha256` file for verification.