#!/bin/bash
# Build FFmpeg-MSwitch for Linux (Ubuntu/Debian)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
RELEASE_DIR="$SCRIPT_DIR/../linux"

echo "=========================================="
echo "FFmpeg-MSwitch Linux Build Script"
echo "=========================================="
echo ""

# Detect architecture
ARCH=$(uname -m)
echo "Building for $ARCH"

# Check if running on Linux
if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: This script must be run on Linux"
    echo "Use Docker or a Linux VM to build Linux binaries"
    exit 1
fi

# Install dependencies
echo "Installing dependencies..."
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    yasm \
    nasm \
    pkg-config \
    git \
    libx264-dev \
    libx265-dev \
    libaom-dev \
    libsrt-openssl-dev \
    libfreetype6-dev \
    libfontconfig1-dev \
    libharfbuzz-dev \
    libssl-dev \
    zlib1g-dev

echo "All dependencies installed."
echo ""

# Clean previous build
echo "Cleaning previous build..."
cd "$FFMPEG_DIR"
make clean 2>/dev/null || true

# Configure
echo "Configuring FFmpeg..."
./configure \
    --prefix="$RELEASE_DIR/ffmpeg-mswitch-$ARCH" \
    --enable-gpl \
    --enable-version3 \
    --enable-nonfree \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libaom \
    --enable-libsrt \
    --enable-libfreetype \
    --enable-libfontconfig \
    --enable-libharfbuzz \
    --enable-protocol=srt \
    --enable-decoder=hevc \
    --enable-decoder=av1 \
    --enable-encoder=libx265 \
    --enable-encoder=libaom-av1 \
    --enable-static \
    --disable-shared \
    --pkg-config-flags="--static"

# Build
echo ""
echo "Building FFmpeg (this may take 10-20 minutes)..."
make -j$(nproc)

# Install to release directory
echo ""
echo "Installing to release directory..."
make install

# Copy SRT relay tools
echo "Copying SRT relay tools..."
mkdir -p "$RELEASE_DIR/ffmpeg-mswitch-$ARCH/tools/srt_relay"
cp -r tools/srt_relay/* "$RELEASE_DIR/ffmpeg-mswitch-$ARCH/tools/srt_relay/"

# Build SRT relay
echo "Building SRT relay..."
cd "$RELEASE_DIR/ffmpeg-mswitch-$ARCH/tools/srt_relay"
make

# Copy documentation
echo "Copying documentation..."
cp "$FFMPEG_DIR/README.md" "$RELEASE_DIR/ffmpeg-mswitch-$ARCH/"
cp "$FFMPEG_DIR/LICENSE.md" "$RELEASE_DIR/ffmpeg-mswitch-$ARCH/" 2>/dev/null || true
cp "$FFMPEG_DIR/COPYING.LGPLv3" "$RELEASE_DIR/ffmpeg-mswitch-$ARCH/"

# Create version file
echo "Creating version file..."
cd "$FFMPEG_DIR"
VERSION=$(./ffmpeg -version | head -n1 | cut -d' ' -f3)
COMMIT=$(git rev-parse --short HEAD)
DATE=$(date +%Y-%m-%d)
DISTRO=$(lsb_release -ds 2>/dev/null || echo "Linux")

cat > "$RELEASE_DIR/ffmpeg-mswitch-$ARCH/VERSION.txt" <<EOF
FFmpeg-MSwitch
Version: $VERSION
Commit: $COMMIT
Build Date: $DATE
Architecture: $ARCH
Platform: $DISTRO

Features:
- Multi-source failover (mswitchdirect demuxer)
- H.264 (libx264)
- HEVC/H.265 (libx265)
- AV1 (libaom-av1)
- SRT protocol
- All standard filters (drawtext, drawbox, overlay, etc.)
- SRT relay server for multi-client support

For documentation, see README.md
EOF

# Create archive
echo ""
echo "Creating archive..."
cd "$RELEASE_DIR"
tar -czf "ffmpeg-mswitch-linux-$ARCH.tar.gz" "ffmpeg-mswitch-$ARCH"

# Calculate checksum
echo "Calculating checksum..."
sha256sum "ffmpeg-mswitch-linux-$ARCH.tar.gz" > "ffmpeg-mswitch-linux-$ARCH.tar.gz.sha256"

echo ""
echo "=========================================="
echo "Build complete!"
echo "=========================================="
echo ""
echo "Release package: $RELEASE_DIR/ffmpeg-mswitch-linux-$ARCH.tar.gz"
echo "Checksum: $RELEASE_DIR/ffmpeg-mswitch-linux-$ARCH.tar.gz.sha256"
echo ""
echo "To test:"
echo "  cd $RELEASE_DIR/ffmpeg-mswitch-$ARCH/bin"
echo "  ./ffmpeg -version"
echo ""
