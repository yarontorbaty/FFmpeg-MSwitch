#!/bin/bash

# Test using HOST FFmpeg only (no Docker)
# This will help isolate if artifacting is from Docker vs local issues

set -e

echo "🔍 Host-Only SRT Rate Control Test"
echo "=================================="

echo "[1/3] Starting VLC..."
# Kill any existing VLC
pkill -f "vlc.*udp" || true
sleep 2

# Start VLC on a free port
VLC_PORT=5404
/Applications/VLC.app/Contents/MacOS/VLC "udp://@:$VLC_PORT" --intf dummy --play-and-exit &
VLC_PID=$!
sleep 3

if ! kill -0 $VLC_PID 2>/dev/null; then
    echo "❌ VLC failed to start"
    exit 1
fi
echo "   ✓ VLC ready on port $VLC_PORT"

echo "[2/3] Starting SRT sender (HOST FFmpeg)..."
SRT_PORT=5558

# Test with HOST FFmpeg (should have our enhanced SRT)
ffmpeg -re -stream_loop -1 \
    -i /tmp/big_buck_bunny_720p.mp4 \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -b:v 4000k -maxrate 4000k -bufsize 8000k \
    -g 50 -sc_threshold 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:$SRT_PORT?mode=listener&latency=2000&rcvbuf=5000000&sndbuf=5000000&enable_stats=1" \
    2>&1 | tee /tmp/host_sender.log &
SENDER_PID=$!

sleep 3

echo "[3/3] Starting SRT receiver (HOST FFmpeg)..."
ffmpeg -hide_banner -loglevel info \
    -protocol_whitelist file,udp,srt \
    -i "srt://127.0.0.1:$SRT_PORT?mode=caller&latency=2000&rcvbuf=5000000&sndbuf=5000000&enable_stats=1" \
    -c copy \
    -f mpegts "udp://127.0.0.1:$VLC_PORT?pkt_size=1316" \
    2>&1 | tee /tmp/host_receiver.log &
RECEIVER_PID=$!

sleep 3

echo ""
echo "🎬 Testing HOST FFmpeg SRT for 30 seconds..."
echo "📺 Watch VLC for video quality"
echo ""

# Run for 30 seconds
sleep 30

echo ""
echo "🏁 Test complete!"
echo ""

# Check results
echo "📊 Host FFmpeg Test Results:"
echo "  - Check VLC playback quality"
echo "  - Check /tmp/host_sender.log for any errors"
echo "  - Check /tmp/host_receiver.log for any errors"

# Show summary
echo ""
echo "📋 Log Summary:"
echo "Sender errors:"
grep -i "error\|failed" /tmp/host_sender.log | head -5 || echo "  No errors found"

echo ""
echo "Receiver errors:"
grep -i "error\|failed" /tmp/host_receiver.log | head -5 || echo "  No errors found"

echo ""
echo "SRT Stats (if any):"
grep "SRT Stats" /tmp/host_sender.log | tail -3 || echo "  No SRT stats found"

# Clean up
kill $SENDER_PID $RECEIVER_PID $VLC_PID 2>/dev/null || true
sleep 2

echo ""
echo "✅ Test complete!"
echo ""
echo "🔍 Analysis:"
echo "  - If video was smooth: Issue is with Docker networking"
echo "  - If video had artifacts: Issue is with local SRT/encoding setup"
