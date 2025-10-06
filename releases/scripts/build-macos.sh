#!/bin/bash
# Build FFmpeg-MSwitch for macOS (Apple Silicon and Intel)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
RELEASE_DIR="$SCRIPT_DIR/../macos"

echo "=========================================="
echo "FFmpeg-MSwitch macOS Build Script"
echo "=========================================="
echo ""

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    echo "Building on Apple Silicon"
    NATIVE_ARCH="arm64"
else
    echo "Building on Intel"
    NATIVE_ARCH="x86_64"
fi

# Ask user what to build
echo ""
echo "Build options:"
echo "1) Native only ($NATIVE_ARCH) - Fast, single architecture"
echo "2) Universal binary (arm64 + x86_64) - Slower, works on all Macs"
echo ""
read -p "Choose [1/2] (default: 1): " BUILD_CHOICE
BUILD_CHOICE=${BUILD_CHOICE:-1}

if [ "$BUILD_CHOICE" = "2" ]; then
    echo "Building universal binary for both architectures..."
    BUILD_UNIVERSAL=true
    ARCH_NAME="universal"
else
    echo "Building for $NATIVE_ARCH only..."
    BUILD_UNIVERSAL=false
    ARCH_NAME="$NATIVE_ARCH"
fi

# Check dependencies
echo "Checking dependencies..."
DEPS="x264 x265 aom srt freetype fontconfig harfbuzz"
MISSING_DEPS=""

for dep in $DEPS; do
    if ! brew list $dep &>/dev/null; then
        MISSING_DEPS="$MISSING_DEPS $dep"
    fi
done

if [ -n "$MISSING_DEPS" ]; then
    echo "Missing dependencies:$MISSING_DEPS"
    echo "Installing with Homebrew..."
    brew install $MISSING_DEPS
fi

echo "All dependencies installed."
echo ""

# Clean previous build
echo "Cleaning previous build..."
cd "$FFMPEG_DIR"
make clean 2>/dev/null || true

if [ "$BUILD_UNIVERSAL" = true ]; then
    # Build for both architectures
    echo ""
    echo "=== Building for arm64 ==="
    ./configure \
        --prefix="$RELEASE_DIR/build-arm64" \
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
        --arch=arm64 \
        --extra-cflags="-arch arm64 -I/opt/homebrew/include" \
        --extra-ldflags="-arch arm64 -L/opt/homebrew/lib" \
        --pkg-config-flags=--static
    
    echo "Building arm64 (this may take 10-20 minutes)..."
    make -j$(sysctl -n hw.ncpu)
    make install
    
    echo ""
    echo "=== Building for x86_64 ==="
    make clean
    ./configure \
        --prefix="$RELEASE_DIR/build-x86_64" \
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
        --arch=x86_64 \
        --extra-cflags="-arch x86_64 -I/opt/homebrew/include -I/usr/local/include" \
        --extra-ldflags="-arch x86_64 -L/opt/homebrew/lib -L/usr/local/lib" \
        --pkg-config-flags=--static
    
    echo "Building x86_64 (this may take 10-20 minutes)..."
    make -j$(sysctl -n hw.ncpu)
    make install
    
    # Create universal binaries
    echo ""
    echo "Creating universal binaries..."
    mkdir -p "$RELEASE_DIR/ffmpeg-mswitch-$ARCH_NAME/bin"
    
    for binary in ffmpeg ffplay ffprobe; do
        if [ -f "$RELEASE_DIR/build-arm64/bin/$binary" ] && [ -f "$RELEASE_DIR/build-x86_64/bin/$binary" ]; then
            echo "  Creating universal $binary..."
            lipo -create \
                "$RELEASE_DIR/build-arm64/bin/$binary" \
                "$RELEASE_DIR/build-x86_64/bin/$binary" \
                -output "$RELEASE_DIR/ffmpeg-mswitch-$ARCH_NAME/bin/$binary"
        fi
    done
    
    # Clean up temporary builds
    rm -rf "$RELEASE_DIR/build-arm64" "$RELEASE_DIR/build-x86_64"
else
    # Build for native architecture only
    echo "Configuring FFmpeg for $NATIVE_ARCH..."
    ./configure \
        --prefix="$RELEASE_DIR/ffmpeg-mswitch-$ARCH_NAME" \
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
        --extra-cflags="-I/opt/homebrew/include" \
        --extra-ldflags="-L/opt/homebrew/lib" \
        --pkg-config-flags=--static
    
    echo ""
    echo "Building FFmpeg (this may take 10-20 minutes)..."
    make -j$(sysctl -n hw.ncpu)
    
    echo ""
    echo "Installing to release directory..."
    make install
fi

# Copy SRT relay tools
echo "Copying SRT relay tools..."
mkdir -p "$RELEASE_DIR/ffmpeg-mswitch-$ARCH_NAME/tools/srt_relay"
cp -r tools/srt_relay/* "$RELEASE_DIR/ffmpeg-mswitch-$ARCH_NAME/tools/srt_relay/"

# Build SRT relay
echo "Building SRT relay..."
cd "$RELEASE_DIR/ffmpeg-mswitch-$ARCH_NAME/tools/srt_relay"
make

# Copy documentation
echo "Copying documentation..."
cp "$FFMPEG_DIR/README.md" "$RELEASE_DIR/ffmpeg-mswitch-$ARCH_NAME/"
cp "$FFMPEG_DIR/LICENSE.md" "$RELEASE_DIR/ffmpeg-mswitch-$ARCH_NAME/" 2>/dev/null || true
cp "$FFMPEG_DIR/COPYING.LGPLv3" "$RELEASE_DIR/ffmpeg-mswitch-$ARCH_NAME/"

# Create version file
echo "Creating version file..."
cd "$FFMPEG_DIR"
VERSION=$(./ffmpeg -version | head -n1 | cut -d' ' -f3)
COMMIT=$(git rev-parse --short HEAD)
DATE=$(date +%Y-%m-%d)

cat > "$RELEASE_DIR/ffmpeg-mswitch-$ARCH_NAME/VERSION.txt" <<EOF
FFmpeg-MSwitch
Version: $VERSION
Commit: $COMMIT
Build Date: $DATE
Architecture: $ARCH_NAME
Platform: macOS $(sw_vers -productVersion)

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
tar -czf "ffmpeg-mswitch-macos-$ARCH_NAME.tar.gz" "ffmpeg-mswitch-$ARCH_NAME"

# Calculate checksum
echo "Calculating checksum..."
shasum -a 256 "ffmpeg-mswitch-macos-$ARCH_NAME.tar.gz" > "ffmpeg-mswitch-macos-$ARCH_NAME.tar.gz.sha256"

echo ""
echo "=========================================="
echo "Build complete!"
echo "=========================================="
echo ""
echo "Release package: $RELEASE_DIR/ffmpeg-mswitch-macos-$ARCH_NAME.tar.gz"
echo "Checksum: $RELEASE_DIR/ffmpeg-mswitch-macos-$ARCH_NAME.tar.gz.sha256"
echo ""
echo "To test:"
echo "  cd $RELEASE_DIR/ffmpeg-mswitch-$ARCH_NAME/bin"
echo "  ./ffmpeg -version"
echo ""
