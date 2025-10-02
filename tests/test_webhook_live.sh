#!/bin/bash
# Live webhook testing script - keeps FFmpeg running for manual testing

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
WEBHOOK_PORT=8099

echo "======================================================"
echo "  MSwitch Webhook Live Testing"
echo "======================================================"
echo ""

# Cleanup function
cleanup() {
    echo -e "\nCleaning up..."
    pkill -9 ffmpeg 2>/dev/null || true
    exit 0
}

trap cleanup EXIT INT TERM

# Kill any existing processes
pkill -9 ffmpeg 2>/dev/null || true
sleep 1

echo "Starting FFmpeg with MSwitch and webhook..."
echo "Webhook will be available at: http://localhost:$WEBHOOK_PORT"
echo ""

# Start FFmpeg with infinite duration (will run until killed)
$FFMPEG_PATH \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local" \
    -msw.webhook.enable \
    -msw.webhook.port $WEBHOOK_PORT \
    -f lavfi -i "color=red:size=640x480:rate=10" \
    -f lavfi -i "color=green:size=640x480:rate=10" \
    -f lavfi -i "color=blue:size=640x480:rate=10" \
    -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -g 50 -pix_fmt yuv420p \
    -f mpegts - 2>&1 | head -50 &

FFMPEG_PID=$!

echo "FFmpeg started (PID: $FFMPEG_PID)"
echo "Waiting for initialization..."
sleep 5

echo ""
echo "======================================================"
echo "  Webhook Commands for Testing"
echo "======================================================"
echo ""
echo "Switch to GREEN (source 1):"
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "       -H 'Content-Type: application/json' -d '{\"source\":\"s1\"}'"
echo ""
echo "Switch to BLUE (source 2):"
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "       -H 'Content-Type: application/json' -d '{\"source\":\"s2\"}'"
echo ""
echo "Switch to RED (source 0):"
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "       -H 'Content-Type: application/json' -d '{\"source\":\"s0\"}'"
echo ""
echo "======================================================"
echo ""
echo "Testing webhook responses..."
echo ""

# Test switch to s1
echo -n "Test 1 - Switch to s1 (GREEN): "
RESPONSE=$(curl -s -X POST http://localhost:$WEBHOOK_PORT/switch \
    -H "Content-Type: application/json" -d '{"source":"s1"}' 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ $RESPONSE"
else
    echo "✗ Failed: $RESPONSE"
fi
sleep 2

# Test switch to s2
echo -n "Test 2 - Switch to s2 (BLUE): "
RESPONSE=$(curl -s -X POST http://localhost:$WEBHOOK_PORT/switch \
    -H "Content-Type: application/json" -d '{"source":"s2"}' 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ $RESPONSE"
else
    echo "✗ Failed: $RESPONSE"
fi
sleep 2

# Test switch to s0
echo -n "Test 3 - Switch to s0 (RED): "
RESPONSE=$(curl -s -X POST http://localhost:$WEBHOOK_PORT/switch \
    -H "Content-Type: application/json" -d '{"source":"s0"}' 2>&1)
if [ $? -eq 0 ]; then
    echo "✓ $RESPONSE"
else
    echo "✗ Failed: $RESPONSE"
fi

echo ""
echo "======================================================"
echo "  Testing Complete"
echo "======================================================"
echo ""
echo "FFmpeg is still running. You can:"
echo "  - Send more curl commands from another terminal"
echo "  - Press Ctrl+C to stop"
echo ""

# Keep script running and wait for FFmpeg
wait $FFMPEG_PID

