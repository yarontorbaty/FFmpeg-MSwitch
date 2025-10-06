# FFmpeg-MSwitch Release Builds

This directory contains scripts for building FFmpeg-MSwitch binaries for macOS, Linux, and Windows.

## Quick Start

### Build for Your Current Platform

```bash
# macOS
./scripts/build-macos.sh

# Linux
./scripts/build-linux.sh

# Windows (in MSYS2 MinGW terminal)
./scripts/build-windows.sh
```

### Build Linux Using Docker (from any platform)

```bash
./scripts/build-all-docker.sh
```

## Platform-Specific Instructions

### macOS

**Requirements:**
- Xcode Command Line Tools
- Homebrew

**Build:**
```bash
cd releases/scripts
chmod +x build-macos.sh
./build-macos.sh
```

**Output:**
- `releases/macos/ffmpeg-mswitch-macos-arm64.tar.gz` (Apple Silicon)
- `releases/macos/ffmpeg-mswitch-macos-x86_64.tar.gz` (Intel)

### Linux

**Requirements:**
- Ubuntu 22.04 or later (or equivalent)
- Build tools and dependencies (installed by script)

**Build:**
```bash
cd releases/scripts
chmod +x build-linux.sh
./build-linux.sh
```

**Output:**
- `releases/linux/ffmpeg-mswitch-linux-x86_64.tar.gz`

**Alternative: Docker Build (from macOS/Windows)**
```bash
cd releases/scripts
chmod +x build-all-docker.sh
./build-all-docker.sh
```

### Windows

**Requirements:**
- MSYS2 with MinGW-w64

**Setup MSYS2:**
1. Download and install MSYS2 from https://www.msys2.org/
2. Open "MSYS2 MinGW 64-bit" terminal
3. Install dependencies:
```bash
pacman -S base-devel mingw-w64-x86_64-toolchain
pacman -S mingw-w64-x86_64-yasm mingw-w64-x86_64-nasm
pacman -S mingw-w64-x86_64-x264 mingw-w64-x86_64-x265
pacman -S mingw-w64-x86_64-aom mingw-w64-x86_64-srt
pacman -S mingw-w64-x86_64-freetype mingw-w64-x86_64-fontconfig
pacman -S mingw-w64-x86_64-harfbuzz
```

**Build:**
```bash
cd releases/scripts
./build-windows.sh
```

**Output:**
- `releases/windows/ffmpeg-mswitch-win64.zip`

## What's Included

Each release package contains:

```
ffmpeg-mswitch-{platform}-{arch}/
├── bin/
│   ├── ffmpeg          # Main executable
│   ├── ffplay          # Media player
│   └── ffprobe         # Stream analyzer
├── tools/
│   └── srt_relay/
│       ├── srt_relay   # SRT relay server
│       ├── mswitch_srt # Helper script
│       └── README.md   # SRT relay documentation
├── README.md           # Full documentation
├── VERSION.txt         # Build information
└── COPYING.LGPLv3      # License
```

## Features Included

All builds include:

### Codecs
- **H.264** (libx264) - Encode and decode
- **HEVC/H.265** (libx265) - Encode and decode
- **AV1** (libaom-av1) - Encode and decode
- All standard FFmpeg codecs

### Protocols
- **SRT** - Secure Reliable Transport
- **UDP** - User Datagram Protocol
- **RTSP** - Real Time Streaming Protocol
- **RTMP** - Real-Time Messaging Protocol
- **HTTP/HTTPS** - Web streaming
- All standard FFmpeg protocols

### Filters
- **drawtext** - Text overlay
- **drawbox** - Box drawing
- **overlay** - Image/video overlay
- **scale** - Resize video
- **crop** - Crop video
- All standard FFmpeg filters

### Custom Features
- **mswitchdirect** - Multi-source failover demuxer
- **SRT relay** - Multi-client SRT server

## Verification

Each release includes a SHA-256 checksum file. Verify downloads:

```bash
# macOS/Linux
sha256sum -c ffmpeg-mswitch-*.tar.gz.sha256

# Windows
certutil -hashfile ffmpeg-mswitch-win64.zip SHA256
```

## Testing

After extracting the archive:

```bash
# Test FFmpeg
cd ffmpeg-mswitch-*/bin
./ffmpeg -version
./ffmpeg -formats | grep mswitchdirect

# Test SRT relay
cd ../tools/srt_relay
./srt_relay 9000 9001 &
```

## Distribution

### GitHub Releases

1. Build all platforms
2. Create a new release on GitHub
3. Upload all `.tar.gz`, `.zip`, and `.sha256` files
4. Tag with version (e.g., `v1.0.0`)

### Release Checklist

- [ ] Build macOS (arm64)
- [ ] Build macOS (x86_64)
- [ ] Build Linux (x86_64)
- [ ] Build Windows (x64)
- [ ] Verify all checksums
- [ ] Test each binary
- [ ] Update CHANGELOG
- [ ] Create GitHub release
- [ ] Upload all artifacts

## Build Times

Approximate build times on modern hardware:

- **macOS (M1/M2):** 10-15 minutes
- **Linux (8 cores):** 15-20 minutes
- **Windows (MSYS2):** 20-30 minutes

## Troubleshooting

### macOS: "Cannot verify developer"
```bash
xattr -d com.apple.quarantine ffmpeg
```

### Linux: Missing dependencies
```bash
sudo apt-get update
sudo apt-get install -f
```

### Windows: DLL errors
Make sure you're running from MSYS2 MinGW terminal, not regular Windows CMD.

## Support

For issues with:
- **Building:** Check platform-specific requirements above
- **Using mswitchdirect:** See main README.md
- **SRT relay:** See tools/srt_relay/README.md

## License

FFmpeg-MSwitch is licensed under LGPL v3 (same as FFmpeg).

See COPYING.LGPLv3 for full license text.
