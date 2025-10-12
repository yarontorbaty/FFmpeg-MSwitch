#!/bin/bash
# Build FFmpeg with Enhanced SRT Integration
# This script builds FFmpeg with the enhanced libsrt library

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Building FFmpeg with Enhanced SRT Integration${NC}"
echo "=================================================="

# Paths
FFMPEG_DIR="/Users/yarontorbaty/Documents/Code/FFmpeg"
SRT_DIR="/Users/yarontorbaty/Documents/Code/srt"
SRT_BUILD_DIR="${SRT_DIR}/build"

# Check if enhanced SRT exists
if [ ! -d "$SRT_DIR" ]; then
    echo -e "${RED}Error: Enhanced SRT directory not found at $SRT_DIR${NC}"
    exit 1
fi

# Check if SRT is built
if [ ! -f "${SRT_BUILD_DIR}/libsrt.dylib" ] && [ ! -f "${SRT_BUILD_DIR}/libsrt.so" ]; then
    echo -e "${YELLOW}Enhanced SRT not built. Building...${NC}"
    cd "$SRT_DIR"
    mkdir -p build
    cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release
    make -j$(sysctl -n hw.ncpu)
    echo -e "${GREEN}Enhanced SRT built successfully${NC}"
fi

cd "$FFMPEG_DIR"

# Clean previous build
echo -e "${YELLOW}Cleaning previous build...${NC}"
make clean 2>/dev/null || true

# Configure FFmpeg
echo -e "${YELLOW}Configuring FFmpeg...${NC}"

# Export to make sure configure picks them up
export PKG_CONFIG_PATH="${SRT_BUILD_DIR}:/opt/homebrew/lib/pkgconfig"
export LDFLAGS="-L${SRT_BUILD_DIR} -Wl,-rpath,${SRT_BUILD_DIR}"
export CFLAGS="-I${SRT_DIR}"

./configure \
    --enable-gpl \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libsrt \
    --extra-ldflags="-L${SRT_BUILD_DIR} -Wl,-rpath,${SRT_BUILD_DIR}" \
    --extra-cflags="-I${SRT_DIR}"

if [ $? -ne 0 ]; then
    echo -e "${RED}Configuration failed!${NC}"
    exit 1
fi

# Build FFmpeg
echo -e "${YELLOW}Building FFmpeg...${NC}"
make -j$(sysctl -n hw.ncpu) 2>&1 | tee build.log

if [ $? -ne 0 ]; then
    echo -e "${RED}Build failed! Check build.log for details${NC}"
    exit 1
fi

echo -e "${GREEN}FFmpeg built successfully with Enhanced libsrt!${NC}"
echo ""
echo "✅ Using Enhanced libsrt v1.5.5 from: ${SRT_BUILD_DIR}"
echo ""
echo "Enhanced Features Available:"
echo ""
echo "1. Bandwidth Monitoring:"
echo "   ./ffmpeg -i input.mp4 -c:v libx264 -f mpegts \"srt://output:4200?enable_stats=1\""
echo ""
echo "2. Auto-Reconnect (no relay needed):"
echo "   ./ffmpeg -i input.mp4 -f mpegts \"srt://output:4200?autoreconnect=1&max_retries=20\""
echo ""
echo "3. MSwitch without relay:"
echo "   ./ffmpeg -i \"srt://src1:4200?autoreconnect=1\" -i \"srt://src2:4201?autoreconnect=1\" \\"
echo "     -filter_complex \"mswitch=inputs=2\" -c copy -f mpegts output.ts"
echo ""
echo "4. NA-VRC Integration:"
echo "   Use srt-live-transmit with --abr yes for your custom NA-VRC"
echo ""
echo -e "${GREEN}Enhanced SRT integration complete!${NC}"
echo ""
echo "📖 See ENHANCED_SRT_BUILD_SUCCESS.md for complete documentation"

