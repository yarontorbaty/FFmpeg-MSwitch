#!/bin/bash
#
# Build Docker image with FFmpeg + Enhanced SRT for testing
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      Building FFmpeg + Enhanced SRT Docker Image             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

cd /Users/yarontorbaty/Documents/Code

echo "This will take 10-15 minutes (full FFmpeg build)..."
echo ""

docker build \
    -f FFmpeg/Dockerfile.ffmpeg-srt-test \
    -t ffmpeg-enhanced-srt:latest \
    .

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Docker image built successfully!"
    echo ""
    echo "Test the image:"
    echo "  docker run --rm ffmpeg-enhanced-srt ffmpeg -version"
    echo "  docker run --rm ffmpeg-enhanced-srt ffmpeg -protocols | grep srt"
    echo ""
    echo "Run netem test:"
    echo "  ./test_docker_netem.sh"
else
    echo ""
    echo "❌ Docker build failed"
    exit 1
fi

