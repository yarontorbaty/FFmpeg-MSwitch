#!/bin/bash
# Automated test to verify MSwitch is actually switching between sources
# Strategy:
# 1. Start 3 color sources (RED, GREEN, BLUE)
# 2. Start MSwitch with webhook enabled
# 3. Send switching commands via webhook
# 4. Extract JPEGs at I-frames
# 5. Analyze JPEG colors to verify switching occurred

set -e

FFMPEG_PATH="./ffmpeg"
TEST_DIR="/tmp/mswitch_test_$$"
mkdir -p "$TEST_DIR"

echo "======================================================"
echo "  MSwitch Switching Verification Test"
echo "======================================================"
echo "Test directory: $TEST_DIR"
echo ""

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    pkill -9 ffmpeg 2>/dev/null || true
    sleep 1
}

trap cleanup EXIT

# Kill any existing FFmpeg processes
cleanup

echo "Step 1: Starting source generators..."
# Generate 3 distinct color sources
$FFMPEG_PATH -f lavfi -i "color=red:size=320x240:rate=5" \
    -c:v libx264 -preset ultrafast -g 5 -pix_fmt yuv420p -tune zerolatency \
    -f mpegts "udp://127.0.0.1:12346" -loglevel error &
sleep 0.5

$FFMPEG_PATH -f lavfi -i "color=green:size=320x240:rate=5" \
    -c:v libx264 -preset ultrafast -g 5 -pix_fmt yuv420p -tune zerolatency \
    -f mpegts "udp://127.0.0.1:12347" -loglevel error &
sleep 0.5

$FFMPEG_PATH -f lavfi -i "color=blue:size=320x240:rate=5" \
    -c:v libx264 -preset ultrafast -g 5 -pix_fmt yuv420p -tune zerolatency \
    -f mpegts "udp://127.0.0.1:12348" -loglevel error &

echo "Waiting for sources to start..."
sleep 3

echo "Step 2: Starting MSwitch with JPEG output..."
# Start MSwitch that outputs JPEGs for every I-frame
$FFMPEG_PATH -loglevel info \
    -msw.enable \
    -msw.sources "s0=udp://127.0.0.1:12346;s1=udp://127.0.0.1:12347;s2=udp://127.0.0.1:12348" \
    -msw.mode graceful \
    -msw.ingest hot \
    -msw.webhook.enable \
    -msw.webhook.port 8099 \
    -i "udp://127.0.0.1:12346" \
    -i "udp://127.0.0.1:12347" \
    -i "udp://127.0.0.1:12348" \
    -map 0:v -vf "select='eq(pict_type\,I)'" -vsync 0 -f image2 "$TEST_DIR/frame_%04d.jpg" \
    -map 1:v -f null - \
    -map 2:v -f null - \
    2>&1 | tee "$TEST_DIR/ffmpeg_log.txt" &

FFMPEG_PID=$!
echo "MSwitch started (PID: $FFMPEG_PID)"

echo "Waiting for MSwitch to initialize..."
sleep 5

# Function to check dominant color in JPEG
check_color() {
    local jpeg="$1"
    if [ ! -f "$jpeg" ]; then
        echo "MISSING"
        return
    fi
    
    # Use ImageMagick if available, otherwise use FFmpeg
    if command -v convert &> /dev/null; then
        # Get average color using ImageMagick
        local color=$(convert "$jpeg" -scale 1x1\! -format '%[pixel:u]' info:-)
        echo "$color"
    else
        # Fallback: check file size as proxy (different colors may compress differently)
        local size=$(stat -f%z "$jpeg" 2>/dev/null || stat -c%s "$jpeg" 2>/dev/null)
        echo "SIZE:$size"
    fi
}

echo ""
echo "Step 3: Testing source switching..."
echo "=================================="

# Test 1: Start with source 0 (RED)
echo ""
echo "Test 1: Initial source should be 0 (RED)"
sleep 2
latest=$(ls -t "$TEST_DIR"/frame_*.jpg 2>/dev/null | head -1)
if [ -n "$latest" ]; then
    color=$(check_color "$latest")
    echo "  Latest frame: $latest"
    echo "  Color: $color"
else
    echo "  ERROR: No frames captured yet!"
fi

# Test 2: Switch to source 1 (GREEN)
echo ""
echo "Test 2: Switching to source 1 (GREEN)..."
curl -s -X POST http://localhost:8099/switch -d '{"source":"s1"}' || echo "  WARNING: Webhook request failed"
sleep 3
latest=$(ls -t "$TEST_DIR"/frame_*.jpg 2>/dev/null | head -1)
if [ -n "$latest" ]; then
    color=$(check_color "$latest")
    echo "  Latest frame: $latest"
    echo "  Color: $color"
    echo "  Expected: GREEN"
fi

# Test 3: Switch to source 2 (BLUE)
echo ""
echo "Test 3: Switching to source 2 (BLUE)..."
curl -s -X POST http://localhost:8099/switch -d '{"source":"s2"}' || echo "  WARNING: Webhook request failed"
sleep 3
latest=$(ls -t "$TEST_DIR"/frame_*.jpg 2>/dev/null | head -1)
if [ -n "$latest" ]; then
    color=$(check_color "$latest")
    echo "  Latest frame: $latest"
    echo "  Color: $color"
    echo "  Expected: BLUE"
fi

# Test 4: Switch back to source 0 (RED)
echo ""
echo "Test 4: Switching back to source 0 (RED)..."
curl -s -X POST http://localhost:8099/switch -d '{"source":"s0"}' || echo "  WARNING: Webhook request failed"
sleep 3
latest=$(ls -t "$TEST_DIR"/frame_*.jpg 2>/dev/null | head -1)
if [ -n "$latest" ]; then
    color=$(check_color "$latest")
    echo "  Latest frame: $latest"
    echo "  Color: $color"
    echo "  Expected: RED"
fi

echo ""
echo "=================================="
echo "Test complete!"
echo ""
echo "Results summary:"
echo "  Total frames captured: $(ls "$TEST_DIR"/frame_*.jpg 2>/dev/null | wc -l)"
echo "  Test directory: $TEST_DIR"
echo "  FFmpeg log: $TEST_DIR/ffmpeg_log.txt"
echo ""
echo "You can manually inspect the JPEGs with:"
echo "  open $TEST_DIR"
echo ""
echo "Analyzing switching patterns..."
echo ""

# Analyze all frames to see switching pattern
frame_num=0
prev_color=""
for frame in "$TEST_DIR"/frame_*.jpg; do
    if [ -f "$frame" ]; then
        color=$(check_color "$frame")
        if [ "$color" != "$prev_color" ]; then
            echo "  Frame $frame_num: $color"
            prev_color="$color"
        fi
        ((frame_num++))
    fi
done

echo ""
echo "Press Enter to cleanup and exit..."
read

