#!/bin/bash

# Simple local test without Docker networking complications
# This will help isolate if artifacting is from local issues

set -e

echo "🔍 Simple Local SRT Rate Control Test"
echo "====================================="

echo "[1/3] Starting VLC..."
# Kill any existing VLC
pkill -f "vlc.*udp" || true
sleep 2

# Start VLC on a free port
VLC_PORT=5403
/Applications/VLC.app/Contents/MacOS/VLC "udp://@:$VLC_PORT" --intf dummy --play-and-exit &
VLC_PID=$!
sleep 3

if ! kill -0 $VLC_PID 2>/dev/null; then
    echo "❌ VLC failed to start"
    exit 1
fi
echo "   ✓ VLC ready on port $VLC_PORT"

echo "[2/3] Starting simple SRT sender (no rate control)..."
SRT_PORT=5557

# Simple test: send Big Buck Bunny without rate control first
ffmpeg -re -stream_loop -1 \
    -i /tmp/big_buck_bunny_720p.mp4 \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -b:v 4000k -maxrate 4000k -bufsize 8000k \
    -g 50 -sc_threshold 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:$SRT_PORT?mode=listener&latency=2000&rcvbuf=5000000&sndbuf=5000000" \
    2>&1 | tee /tmp/simple_sender.log &
SIMPLE_PID=$!

sleep 3

echo "[3/3] Starting SRT receiver..."
ffmpeg -hide_banner -loglevel info \
    -protocol_whitelist file,udp,srt \
    -i "srt://127.0.0.1:$SRT_PORT?mode=caller&latency=2000&rcvbuf=5000000&sndbuf=5000000" \
    -c copy \
    -f mpegts "udp://127.0.0.1:$VLC_PORT?pkt_size=1316" \
    2>&1 | tee /tmp/simple_receiver.log &
RECEIVER_PID=$!

sleep 3

echo ""
echo "🎬 Testing simple SRT (no rate control) for 30 seconds..."
echo "📺 Watch VLC for video quality"
echo ""

# Run for 30 seconds
sleep 30

echo ""
echo "🏁 Test complete!"
echo ""

# Check results
echo "📊 Simple SRT Test Results:"
echo "  - Check VLC playback quality"
echo "  - Check /tmp/simple_sender.log for any errors"
echo "  - Check /tmp/simple_receiver.log for any errors"

# Show summary
echo ""
echo "📋 Log Summary:"
echo "Sender errors:"
grep -i "error\|failed" /tmp/simple_sender.log | head -5 || echo "  No errors found"

echo ""
echo "Receiver errors:"
grep -i "error\|failed" /tmp/simple_receiver.log | head -5 || echo "  No errors found"

# Clean up
kill $SIMPLE_PID $RECEIVER_PID $VLC_PID 2>/dev/null || true
sleep 2

echo ""
echo "✅ Test complete!"
echo ""
echo "🔍 Analysis:"
echo "  - If video was smooth: SRT itself is fine, issue is with rate control"
echo "  - If video had artifacts: Issue is with SRT configuration or local setup"
