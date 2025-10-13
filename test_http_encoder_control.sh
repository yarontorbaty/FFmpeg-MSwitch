#!/bin/bash

# Test HTTP-based encoder control
# This test uses testsrc to generate video and controls the encoder via HTTP commands

set -e

echo "═══════════════════════════════════════════════════════════"
echo "  HTTP Encoder Control Test"
echo "═══════════════════════════════════════════════════════════"

# Config
HTTP_PORT=8080
DURATION=60  # 60 seconds total
SRT_PORT=9999

# Cleanup
cleanup() {
    echo "Cleaning up..."
    pkill -f "ffmpeg.*http_control" || true
    pkill -f "ffplay.*srt" || true
    sleep 1
}

trap cleanup EXIT
cleanup

# Start FFmpeg with HTTP control enabled
echo ""
echo "Starting FFmpeg encoder with HTTP control on port $HTTP_PORT..."
./ffmpeg -re -f lavfi -i testsrc=duration=${DURATION}:size=1280x720:rate=30 \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -b:v 10000k \
    -g 60 -sc_threshold 0 \
    -http_control_enable 1 \
    -http_control_port ${HTTP_PORT} \
    -f mpegts "srt://127.0.0.1:${SRT_PORT}?mode=listener&latency=1000" \
    2>&1 | tee /tmp/http_control_test.log &

FFMPEG_PID=$!
echo "FFmpeg PID: $FFMPEG_PID"

# Wait for encoder to initialize
sleep 3

# Start VLC player
echo ""
echo "Starting VLC player..."
open -a VLC "srt://127.0.0.1:${SRT_PORT}?mode=caller" &
sleep 2

# Send HTTP commands to control the encoder
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Sending Encoder Control Commands"
echo "═══════════════════════════════════════════════════════════"

# Command 1: Set bitrate to 5 Mbps (after 5s)
sleep 5
echo ""
echo "[$(date +%T)] ➤ Command 1: Set bitrate to 5000 kbps"
curl -X POST http://localhost:${HTTP_PORT} \
    -H "Content-Type: application/json" \
    -d '{"bitrate":5000}' \
    2>/dev/null
echo " [SENT]"

# Command 2: Set bitrate to 2 Mbps + force IDR (after 10s)
sleep 5
echo ""
echo "[$(date +%T)] ➤ Command 2: Set bitrate to 2000 kbps + Force IDR"
curl -X POST http://localhost:${HTTP_PORT} \
    -H "Content-Type: application/json" \
    -d '{"bitrate":2000,"force_idr":1}' \
    2>/dev/null
echo " [SENT]"

# Command 3: Set bitrate to 15 Mbps (after 15s)
sleep 5
echo ""
echo "[$(date +%T)] ➤ Command 3: Set bitrate to 15000 kbps"
curl -X POST http://localhost:${HTTP_PORT} \
    -H "Content-Type: application/json" \
    -d '{"bitrate":15000}' \
    2>/dev/null
echo " [SENT]"

# Command 4: Set FPS to 15 (after 20s)
sleep 5
echo ""
echo "[$(date +%T)] ➤ Command 4: Set FPS to 15"
curl -X POST http://localhost:${HTTP_PORT} \
    -H "Content-Type: application/json" \
    -d '{"fps":15}' \
    2>/dev/null
echo " [SENT]"

# Command 5: Set bitrate to 8 Mbps + FPS to 30 (after 25s)
sleep 5
echo ""
echo "[$(date +%T)] ➤ Command 5: Set bitrate to 8000 kbps + FPS to 30"
curl -X POST http://localhost:${HTTP_PORT} \
    -H "Content-Type: application/json" \
    -d '{"bitrate":8000,"fps":30}' \
    2>/dev/null
echo " [SENT]"

# Command 6: Custom VBV settings (after 30s)
sleep 5
echo ""
echo "[$(date +%T)] ➤ Command 6: Set bitrate to 3000 kbps with custom VBV"
curl -X POST http://localhost:${HTTP_PORT} \
    -H "Content-Type: application/json" \
    -d '{"bitrate":3000,"vbv_maxrate":3600,"vbv_bufsize":1500}' \
    2>/dev/null
echo " [SENT]"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Commands sent. Let encoder run for remaining time..."
echo "═══════════════════════════════════════════════════════════"

# Wait for FFmpeg to finish
wait $FFMPEG_PID

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Test Complete!"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Check /tmp/http_control_test.log for detailed encoder logs"
echo ""
echo "Expected log patterns:"
echo "  - [HTTP Control] ═══ RECEIVED COMMAND ═══"
echo "  - [HTTP Control] ✓ ✓ ✓ RECONFIG SUCCESS ✓ ✓ ✓"
echo ""

