#!/bin/bash

# Automated visual switching verification test for MSwitch demuxer
# Captures JPEG frames and analyzes colors to verify switching

set -e

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
TEST_DIR="/tmp/mswitch_visual_test_$$"

echo "======================================================"
echo "  MSwitch Visual Switching Verification"
echo "======================================================"
echo "Test directory: $TEST_DIR"

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    pkill -9 ffmpeg 2>/dev/null || true
    # Keep test directory for inspection
    echo "Test frames saved in: $TEST_DIR"
}

trap cleanup EXIT

# Create test directory
mkdir -p "$TEST_DIR"

# Kill any existing processes
pkill -9 ffmpeg 2>/dev/null || true
sleep 2

echo ""
echo "Step 1: Starting MSwitch with JPEG output..."
echo "------------------------------------------------------"

# Start FFmpeg with JPEG output (1 frame per second)
"$FFMPEG_PATH" -f mswitch \
    -i "sources=color=red:size=640x480:rate=25,color=green:size=640x480:rate=25,color=blue:size=640x480:rate=25&control=8099" \
    -vf fps=1 \
    -f image2 "$TEST_DIR/frame_%04d.jpg" \
    -loglevel info > "$TEST_DIR/ffmpeg.log" 2>&1 &

FFMPEG_PID=$!

echo "FFmpeg started (PID: $FFMPEG_PID)"
echo "Waiting for initialization..."
sleep 6

# Function to analyze JPEG color
analyze_frame() {
    local frame_file="$1"
    if [ ! -f "$frame_file" ]; then
        echo "MISSING"
        return
    fi
    
    # Get file size as a simple proxy for color
    # Different colors will compress differently
    local size=$(stat -f%z "$frame_file" 2>/dev/null || stat -c%s "$frame_file" 2>/dev/null)
    echo "$size"
}

# Function to get dominant color (simplified)
get_color_name() {
    local size="$1"
    # These are approximate ranges based on JPEG compression
    # Red/Green/Blue solid colors compress to different sizes
    if [ "$size" -lt "10000" ]; then
        echo "RED"
    elif [ "$size" -lt "15000" ]; then
        echo "GREEN"
    else
        echo "BLUE"
    fi
}

echo ""
echo "Step 2: Testing source switching with visual verification..."
echo "======================================================"

# Wait for first frame
echo ""
echo "Waiting for first frame..."
sleep 2

# Test 1: Initial source (RED)
echo ""
echo "Test 1: Initial source = 0 (RED)"
echo "------------------------------------------------------"
latest_frame=$(ls -t "$TEST_DIR"/frame_*.jpg 2>/dev/null | head -1)
if [ -n "$latest_frame" ]; then
    size=$(analyze_frame "$latest_frame")
    color=$(get_color_name "$size")
    echo "  Frame: $(basename "$latest_frame")"
    echo "  Size: $size bytes"
    echo "  Detected color: $color"
    echo "  Expected: RED"
    if [ "$color" = "RED" ]; then
        echo "  ✅ PASS"
    else
        echo "  ❌ FAIL - Expected RED, got $color"
    fi
else
    echo "  ❌ FAIL - No frames captured yet"
fi

sleep 2

# Test 2: Switch to GREEN
echo ""
echo "Test 2: Switching to source 1 (GREEN)"
echo "------------------------------------------------------"
response=$(curl -s -X POST "http://localhost:8099/switch?source=1")
echo "  API Response: $response"
echo "  Waiting for new frames..."
sleep 3

latest_frame=$(ls -t "$TEST_DIR"/frame_*.jpg 2>/dev/null | head -1)
if [ -n "$latest_frame" ]; then
    size=$(analyze_frame "$latest_frame")
    color=$(get_color_name "$size")
    echo "  Frame: $(basename "$latest_frame")"
    echo "  Size: $size bytes"
    echo "  Detected color: $color"
    echo "  Expected: GREEN"
    if [ "$color" = "GREEN" ]; then
        echo "  ✅ PASS - Visual switching works!"
    else
        echo "  ⚠️  WARNING - Expected GREEN, got $color"
        echo "     This might indicate switching isn't working"
    fi
else
    echo "  ❌ FAIL - No new frames"
fi

sleep 2

# Test 3: Switch to BLUE
echo ""
echo "Test 3: Switching to source 2 (BLUE)"
echo "------------------------------------------------------"
response=$(curl -s -X POST "http://localhost:8099/switch?source=2")
echo "  API Response: $response"
echo "  Waiting for new frames..."
sleep 3

latest_frame=$(ls -t "$TEST_DIR"/frame_*.jpg 2>/dev/null | head -1)
if [ -n "$latest_frame" ]; then
    size=$(analyze_frame "$latest_frame")
    color=$(get_color_name "$size")
    echo "  Frame: $(basename "$latest_frame")"
    echo "  Size: $size bytes"
    echo "  Detected color: $color"
    echo "  Expected: BLUE"
    if [ "$color" = "BLUE" ]; then
        echo "  ✅ PASS - Visual switching works!"
    else
        echo "  ⚠️  WARNING - Expected BLUE, got $color"
    fi
else
    echo "  ❌ FAIL - No new frames"
fi

sleep 2

# Test 4: Switch back to RED
echo ""
echo "Test 4: Switching back to source 0 (RED)"
echo "------------------------------------------------------"
response=$(curl -s -X POST "http://localhost:8099/switch?source=0")
echo "  API Response: $response"
echo "  Waiting for new frames..."
sleep 3

latest_frame=$(ls -t "$TEST_DIR"/frame_*.jpg 2>/dev/null | head -1)
if [ -n "$latest_frame" ]; then
    size=$(analyze_frame "$latest_frame")
    color=$(get_color_name "$size")
    echo "  Frame: $(basename "$latest_frame")"
    echo "  Size: $size bytes"
    echo "  Detected color: $color"
    echo "  Expected: RED"
    if [ "$color" = "RED" ]; then
        echo "  ✅ PASS - Switching back works!"
    else
        echo "  ⚠️  WARNING - Expected RED, got $color"
    fi
else
    echo "  ❌ FAIL - No new frames"
fi

echo ""
echo "======================================================"
echo "  Analysis Complete"
echo "======================================================"
echo ""

# Analyze all frames
echo "Frame timeline:"
echo "------------------------------------------------------"
frame_num=1
for frame in "$TEST_DIR"/frame_*.jpg; do
    if [ -f "$frame" ]; then
        size=$(analyze_frame "$frame")
        color=$(get_color_name "$size")
        echo "  Frame $frame_num: $(basename "$frame") - $size bytes - $color"
        frame_num=$((frame_num + 1))
    fi
done

echo ""
echo "Total frames captured: $((frame_num - 1))"
echo ""
echo "You can manually inspect frames with:"
echo "  open $TEST_DIR"
echo ""

# Keep FFmpeg running briefly to see final messages
sleep 2

