#!/bin/bash

# Test script for MSwitch custom demuxer with visual switching

set -e

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"

echo "======================================================"
echo "  MSwitch Visual Switching Test"
echo "======================================================"

# Kill any existing ffmpeg/ffplay processes
echo "Cleaning up existing processes..."
pkill -9 ffmpeg ffplay 2>/dev/null || true
sleep 2

echo ""
echo "Starting MSwitch with ffplay output..."
echo "You should see a RED screen initially."
echo "------------------------------------------------------"

# Start FFmpeg with ffplay in background
"$FFMPEG_PATH" -f mswitch \
    -i "sources=color=red:size=640x480:rate=25,color=green:size=640x480:rate=25,color=blue:size=640x480:rate=25&control=8099" \
    -c:v libx264 -preset ultrafast -g 50 -pix_fmt yuv420p \
    -f mpegts - 2>&1 | ffplay -i - -loglevel warning &

FFMPEG_PID=$!

echo "FFmpeg started (PID: $FFMPEG_PID)"
echo "Waiting for initialization..."
sleep 8

echo ""
echo "Testing source switching..."
echo "======================================================"

echo ""
echo "Test 1: Initial source = 0 (RED)"
echo "  You should be seeing RED"
sleep 3

echo ""
echo "Test 2: Switching to source 1 (GREEN)..."
curl -s -X POST "http://localhost:8099/switch?source=1"
echo ""
echo "  You should now see GREEN"
sleep 5

echo ""
echo "Test 3: Switching to source 2 (BLUE)..."
curl -s -X POST "http://localhost:8099/switch?source=2"
echo ""
echo "  You should now see BLUE"
sleep 5

echo ""
echo "Test 4: Switching back to source 0 (RED)..."
curl -s -X POST "http://localhost:8099/switch?source=0"
echo ""
echo "  You should now see RED again"
sleep 5

echo ""
echo "Test 5: Rapid switching..."
for i in {1..3}; do
    echo "  Switch to source $((i % 3))..."
    curl -s -X POST "http://localhost:8099/switch?source=$((i % 3))"
    sleep 2
done

echo ""
echo "======================================================"
echo "  Test Complete!"
echo "======================================================"
echo ""
echo "FFmpeg is still running. Close the ffplay window or press Ctrl+C to exit."
echo ""

# Wait for user or timeout
sleep 30

# Cleanup
echo "Cleaning up..."
pkill -9 ffmpeg ffplay 2>/dev/null || true

echo "Done!"

