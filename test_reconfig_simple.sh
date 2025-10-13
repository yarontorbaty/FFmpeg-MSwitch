#!/bin/bash
#
# Simple test to verify x264_encoder_reconfig() is being called and accepted
# No network emulation, just test the encoder response
#

set -e

SRT_PORT=9000
VLC_PORT=5400

cleanup() {
    echo "Cleaning up..."
    pkill -f "ffmpeg.*srt://127" 2>/dev/null || true
    pkill -f "ffmpeg.*srt://0.0.0" 2>/dev/null || true
    pkill -f "VLC" 2>/dev/null || true
    sleep 1
}
trap cleanup EXIT INT

cleanup

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   SIMPLE RECONFIG TEST (No Network Stress)                  ║"
echo "║   Testing if x264_encoder_reconfig() actually works         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Start VLC
echo "[1/3] Starting VLC..."
/Applications/VLC.app/Contents/MacOS/VLC "udp://@:${VLC_PORT}" > /dev/null 2>&1 &
sleep 3
echo "   ✓ VLC ready"
echo ""

# Start receiver
echo "[2/3] Starting SRT receiver..."
./ffmpeg -hide_banner -loglevel info \
    -protocol_whitelist file,udp,srt \
    -i "srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=3000&rcvbuf=10000000&sndbuf=10000000&enable_stats=1" \
    -c copy \
    -f mpegts "udp://127.0.0.1:${VLC_PORT}?pkt_size=1316" \
    2>&1 | grep --line-buffered "SRT Stats" &
RX_PID=$!
sleep 3
echo "   ✓ Receiver started"
echo ""

# Start sender with SRT rate control enabled
echo "[3/3] Starting sender with SRT Rate Control..."
echo "   Min: 5 Mbps, Max: 25 Mbps"
echo "   Watch for '[SRT Rate Control] CALLING x264_encoder_reconfig()' messages"
echo ""

./ffmpeg -re -stream_loop -1 \
    -i /tmp/big_buck_bunny_720p.mp4 \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -b:v 20000k \
    -g 50 -sc_threshold 0 \
    -srt_rate_control 1 \
    -srt_min_bitrate 5000000 \
    -srt_max_bitrate 25000000 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:${SRT_PORT}?latency=3000&rcvbuf=10000000&sndbuf=10000000&enable_stats=1" \
    2>&1 | grep --line-buffered -E "(SRT Rate Control|bitrate=)" &
TX_PID=$!

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  RUNNING FOR 60 SECONDS"
echo "  NO NETWORK STRESS - Just testing reconfig calls"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

sleep 60

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TEST COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

kill $TX_PID $RX_PID 2>/dev/null || true

