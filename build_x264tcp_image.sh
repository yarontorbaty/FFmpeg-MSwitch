#!/bin/bash
#
# Build Docker image with x264 TCP control support
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Building FFmpeg + Enhanced SRT + x264 TCP Control          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

cd /Users/yarontorbaty/Documents/Code

echo "Building x264 from source for TCP control..."
echo "This will take 15-20 minutes..."
echo ""

docker build \
    -f FFmpeg/Dockerfile.ffmpeg-srt-x264tcp \
    -t ffmpeg-srt-x264tcp:latest \
    .

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Docker image built successfully!"
    echo ""
    echo "Test x264 TCP control:"
    echo "  docker run --rm ffmpeg-srt-x264tcp x264 --help | grep tcp"
    echo ""
    echo "Run dynamic bitrate test:"
    echo "  ./test_dynamic_bitrate_vlc.sh  # (update to use new image)"
else
    echo ""
    echo "❌ Docker build failed"
    exit 1
fi

