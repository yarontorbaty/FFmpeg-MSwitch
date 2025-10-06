#!/bin/bash
# Build FFmpeg-MSwitch for Windows (using MSYS2/MinGW)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
RELEASE_DIR="$SCRIPT_DIR/../windows"

echo "=========================================="
echo "FFmpeg-MSwitch Windows Build Script"
echo "=========================================="
echo ""

# Check if running in MSYS2/MinGW environment
if [[ ! "$MSYSTEM" =~ ^MINGW ]]; then
    echo "ERROR: This script must be run in MSYS2 MinGW environment"
    echo ""
    echo "Setup instructions:"
    echo "1. Install MSYS2 from https://www.msys2.org/"
    echo "2. Open 'MSYS2 MinGW 64-bit' terminal"
    echo "3. Install dependencies:"
    echo "   pacman -S base-devel mingw-w64-x86_64-toolchain"
    echo "   pacman -S mingw-w64-x86_64-yasm mingw-w64-x86_64-nasm"
    echo "   pacman -S mingw-w64-x86_64-x264 mingw-w64-x86_64-x265"
    echo "   pacman -S mingw-w64-x86_64-aom mingw-w64-x86_64-srt"
    echo "   pacman -S mingw-w64-x86_64-freetype mingw-w64-x86_64-fontconfig"
    echo "   pacman -S mingw-w64-x86_64-harfbuzz"
    echo "4. Run this script again"
    exit 1
fi

# Detect architecture
if [ "$MSYSTEM" = "MINGW64" ]; then
    ARCH="x86_64"
    echo "Building for Windows x86_64"
elif [ "$MSYSTEM" = "MINGW32" ]; then
    ARCH="i686"
    echo "Building for Windows i686"
else
    echo "ERROR: Unknown MSYSTEM: $MSYSTEM"
    exit 1
fi

# Check dependencies
echo "Checking dependencies..."
DEPS="x264 x265 aom srt freetype fontconfig harfbuzz"
MISSING_DEPS=""

for dep in $DEPS; do
    if ! pacman -Q mingw-w64-$ARCH-$dep &>/dev/null; then
        MISSING_DEPS="$MISSING_DEPS mingw-w64-$ARCH-$dep"
    fi
done

if [ -n "$MISSING_DEPS" ]; then
    echo "Missing dependencies:$MISSING_DEPS"
    echo "Install with: pacman -S$MISSING_DEPS"
    exit 1
fi

echo "All dependencies installed."
echo ""

# Clean previous build
echo "Cleaning previous build..."
cd "$FFMPEG_DIR"
make clean 2>/dev/null || true

# Configure
echo "Configuring FFmpeg..."
./configure \
    --prefix="$RELEASE_DIR/ffmpeg-mswitch-win64" \
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
    --arch=$ARCH \
    --target-os=mingw32 \
    --cross-prefix=$ARCH-w64-mingw32- \
    --pkg-config=pkg-config \
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
mkdir -p "$RELEASE_DIR/ffmpeg-mswitch-win64/tools/srt_relay"
cp -r tools/srt_relay/* "$RELEASE_DIR/ffmpeg-mswitch-win64/tools/srt_relay/"

# Build SRT relay
echo "Building SRT relay..."
cd "$RELEASE_DIR/ffmpeg-mswitch-win64/tools/srt_relay"
make CC=$ARCH-w64-mingw32-gcc

# Copy documentation
echo "Copying documentation..."
cp "$FFMPEG_DIR/README.md" "$RELEASE_DIR/ffmpeg-mswitch-win64/"
cp "$FFMPEG_DIR/LICENSE.md" "$RELEASE_DIR/ffmpeg-mswitch-win64/" 2>/dev/null || true
cp "$FFMPEG_DIR/COPYING.LGPLv3" "$RELEASE_DIR/ffmpeg-mswitch-win64/"

# Create version file
echo "Creating version file..."
cd "$FFMPEG_DIR"
VERSION=$(./ffmpeg.exe -version | head -n1 | cut -d' ' -f3)
COMMIT=$(git rev-parse --short HEAD)
DATE=$(date +%Y-%m-%d)

cat > "$RELEASE_DIR/ffmpeg-mswitch-win64/VERSION.txt" <<EOF
FFmpeg-MSwitch
Version: $VERSION
Commit: $COMMIT
Build Date: $DATE
Architecture: $ARCH
Platform: Windows

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
zip -r "ffmpeg-mswitch-win64.zip" "ffmpeg-mswitch-win64"

# Calculate checksum
echo "Calculating checksum..."
sha256sum "ffmpeg-mswitch-win64.zip" > "ffmpeg-mswitch-win64.zip.sha256"

echo ""
echo "=========================================="
echo "Build complete!"
echo "=========================================="
echo ""
echo "Release package: $RELEASE_DIR/ffmpeg-mswitch-win64.zip"
echo "Checksum: $RELEASE_DIR/ffmpeg-mswitch-win64.zip.sha256"
echo ""
echo "To test:"
echo "  cd $RELEASE_DIR/ffmpeg-mswitch-win64/bin"
echo "  ./ffmpeg.exe -version"
echo ""
