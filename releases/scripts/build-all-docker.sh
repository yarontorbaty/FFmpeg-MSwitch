#!/bin/bash
# Build FFmpeg-MSwitch for all platforms using Docker

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "=========================================="
echo "FFmpeg-MSwitch Multi-Platform Build"
echo "=========================================="
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed"
    echo "Install Docker from https://www.docker.com/"
    exit 1
fi

echo "Building for Linux (x86_64) using Docker..."
echo ""

# Build Linux version
cd "$FFMPEG_DIR"
docker build -f releases/scripts/Dockerfile.linux -t ffmpeg-mswitch-builder:linux .
docker run --rm -v "$FFMPEG_DIR/releases/linux:/build/releases/linux" ffmpeg-mswitch-builder:linux

echo ""
echo "=========================================="
echo "Linux build complete!"
echo "=========================================="
echo ""
echo "Note: macOS and Windows builds must be done natively:"
echo "  - macOS: Run releases/scripts/build-macos.sh on a Mac"
echo "  - Windows: Run releases/scripts/build-windows.sh in MSYS2"
echo ""
echo "All builds will be in releases/ directory:"
echo "  - releases/linux/ffmpeg-mswitch-linux-x86_64.tar.gz"
echo "  - releases/macos/ffmpeg-mswitch-macos-arm64.tar.gz"
echo "  - releases/macos/ffmpeg-mswitch-macos-x86_64.tar.gz"
echo "  - releases/windows/ffmpeg-mswitch-win64.zip"
echo ""
