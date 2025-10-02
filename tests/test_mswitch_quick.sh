#!/bin/bash

# Quick MSwitch visual test - runs to completion automatically

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
TEST_DIR="/tmp/mswitch_quick_$$"

echo "MSwitch Quick Visual Test"
echo "=========================="

# Cleanup
pkill -9 ffmpeg 2>/dev/null
sleep 1
mkdir -p "$TEST_DIR"

# Start FFmpeg with JPEG output in background
"$FFMPEG_PATH" -f mswitch \
    -i "sources=color=red:size=320x240:rate=10,color=green:size=320x240:rate=10,color=blue:size=320x240:rate=10&control=8099" \
    -vf fps=1 -f image2 "$TEST_DIR/frame_%04d.jpg" \
    > "$TEST_DIR/ffmpeg.log" 2>&1 &

FFMPEG_PID=$!
echo "FFmpeg started (PID: $FFMPEG_PID)"
sleep 4

# Test switches
echo "Switch to source 1 (GREEN)..."
curl -s -X POST "http://localhost:8099/switch?source=1"
sleep 3

echo "Switch to source 2 (BLUE)..."
curl -s -X POST "http://localhost:8099/switch?source=2"
sleep 3

echo "Switch to source 0 (RED)..."
curl -s -X POST "http://localhost:8099/switch?source=0"
sleep 3

# Kill FFmpeg
kill $FFMPEG_PID 2>/dev/null
wait $FFMPEG_PID 2>/dev/null

# Analyze frames
echo ""
echo "Analyzing frames..."
for i in 1 2 5 7 10; do
    frame=$(printf "$TEST_DIR/frame_%04d.jpg" $i)
    if [ -f "$frame" ]; then
        size=$(stat -f%z "$frame" 2>/dev/null || stat -c%s "$frame" 2>/dev/null)
        echo "  Frame $i: $size bytes"
    fi
done

# Check logs
echo ""
echo "Switch events:"
grep -i "switched" "$TEST_DIR/ffmpeg.log" | head -5

echo ""
echo "Proxy forwarding (sample):"
grep "Forwarded packet from source [12]" "$TEST_DIR/ffmpeg.log" | head -3

echo ""
echo "Test complete. Files in: $TEST_DIR"

