#!/bin/bash
#
# Debug test - check if FFmpeg runs inside Docker
#

docker run --rm --cap-add=NET_ADMIN \
    -v /Users/yarontorbaty/Documents/Code/FFmpeg:/ffmpeg:ro \
    srt-navrc-test \
    bash -c '
echo "Testing FFmpeg..."
/ffmpeg/ffmpeg -version 2>&1 | head -5
echo ""
echo "Testing SRT support..."
/ffmpeg/ffmpeg -protocols 2>&1 | grep -i srt
echo ""
echo "Starting quick test..."

# Start receiver
/ffmpeg/ffmpeg -hide_banner -loglevel info \
    -protocol_whitelist file,udp,srt \
    -i "srt://127.0.0.1:4200?mode=listener&latency=100&enable_stats=1" \
    -c copy -f null - &
RECEIVER_PID=$!
sleep 2

# Start sender
/ffmpeg/ffmpeg -hide_banner -loglevel info -re \
    -f lavfi -i "testsrc=size=320x240:rate=25:duration=15" \
    -c:v libx264 -preset veryfast -b:v 1M \
    -f mpegts "srt://127.0.0.1:4200?latency=100&enable_stats=1" 2>&1 | grep -E "SRT Stats|frame=" | head -20

kill $RECEIVER_PID 2>/dev/null || true
sleep 1

echo ""
echo "Test complete"
'

