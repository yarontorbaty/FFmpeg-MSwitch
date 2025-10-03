#!/bin/bash

# Simple webhook test script

echo "Testing MSwitch Webhook Server..."
echo ""

# Kill any existing processes
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 1

echo "Starting FFmpeg with webhook server..."
./ffmpeg -msw.enable -msw.sources "s0=local;s1=local;s2=local" \
    -msw.webhook.enable -msw.webhook.port 8099 \
    -f lavfi -i "color=red:size=640x480:rate=10" \
    -f lavfi -i "color=green:size=640x480:rate=10" \
    -f lavfi -i "color=blue:size=640x480:rate=10" \
    -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0,fps=10[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -g 1 -keyint_min 1 -sc_threshold 0 \
    -pix_fmt yuv420p \
    -f mpegts - | ffplay -i - -loglevel warning &

FFMPEG_PID=$!
echo "FFmpeg PID: $FFMPEG_PID"

# Wait for webhook server to start
echo "Waiting for webhook server to start..."
sleep 3

# Test webhook connection
echo "Testing webhook connection..."
curl -X POST http://localhost:8099/switch \
    -H 'Content-Type: application/json' \
    -d '{"source":"s1"}' \
    --connect-timeout 5 \
    --max-time 10

echo ""
echo "Webhook test complete. Killing FFmpeg..."
kill $FFMPEG_PID 2>/dev/null
pkill -9 ffmpeg ffplay 2>/dev/null
