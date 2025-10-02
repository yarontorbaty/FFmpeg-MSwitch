#!/bin/bash

# Test script for MSwitch custom demuxer
# This tests the custom mswitch:// protocol

set -e

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
FFPLAY_PATH="${FFPLAY_PATH:-ffplay}"

echo "======================================================"
echo "  MSwitch Custom Demuxer Test"
echo "======================================================"

# Kill any existing ffmpeg/ffplay processes
echo "Cleaning up existing processes..."
pkill -9 ffmpeg ffplay 2>/dev/null || true
sleep 1

# Test 1: Basic demuxer functionality
echo ""
echo "Test 1: Starting MSwitch demuxer with lavfi sources"
echo "------------------------------------------------------"

"$FFMPEG_PATH" \
    -i "mswitch://?sources=color=red:size=320x240:rate=10,color=green:size=320x240:rate=10,color=blue:size=320x240:rate=10&control=8099" \
    -c:v libx264 -preset ultrafast -g 50 -pix_fmt yuv420p \
    -f mpegts - 2>&1 | "$FFPLAY_PATH" -i - &

FFMPEG_PID=$!

echo "FFmpeg started (PID: $FFMPEG_PID)"
echo "Waiting for initialization..."
sleep 5

# Test 2: Check if control server is responding
echo ""
echo "Test 2: Testing control server"
echo "------------------------------------------------------"

echo "Getting status..."
curl -s http://localhost:8099/status
echo ""

# Test 3: Switch sources
echo ""
echo "Test 3: Testing source switching"
echo "------------------------------------------------------"

echo "Initial source: 0 (RED)"
sleep 2

echo "Switching to source 1 (GREEN)..."
curl -s -X POST "http://localhost:8099/switch?source=1"
echo ""
sleep 3

echo "Switching to source 2 (BLUE)..."
curl -s -X POST "http://localhost:8099/switch?source=2"
echo ""
sleep 3

echo "Switching back to source 0 (RED)..."
curl -s -X POST "http://localhost:8099/switch?source=0"
echo ""
sleep 3

# Test 4: Status check
echo ""
echo "Test 4: Final status check"
echo "------------------------------------------------------"
curl -s http://localhost:8099/status
echo ""

echo ""
echo "======================================================"
echo "  Test Complete!"
echo "======================================================"
echo ""
echo "FFmpeg is still running. You should see visual switching."
echo "Press Ctrl+C when done to cleanup."
echo ""

# Wait for user to kill or timeout after 60 seconds
sleep 60

# Cleanup
echo "Cleaning up..."
kill -9 $FFMPEG_PID 2>/dev/null || true
pkill -9 ffplay 2>/dev/null || true

echo "Done!"

