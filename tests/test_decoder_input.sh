#!/bin/bash

# Test to see exactly what the H.264 decoder receives
# This will show the sequence of NAL units reaching the decoder

LOG_FILE="/Users/yarontorbaty/Documents/Code/FFmpeg/decoder_input_test.log"
rm -f "$LOG_FILE"

echo "Starting decoder input test..."
echo "This will show exactly what NAL units the H.264 decoder receives"
echo ""

# Start FFmpeg with all three sources
./ffmpeg -hide_banner -loglevel info \
    -f mswitchdirect \
    -msw_sources "udp://127.0.0.1:5000,udp://127.0.0.1:5001,udp://127.0.0.1:5002" \
    -msw_port 9090 \
    -msw_auto 1 \
    -msw_timeout 500 \
    -msw_check_interval 50 \
    -msw_grace 0 \
    -i dummy \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -keyint_min 60 \
    -f mpegts - 2>"$LOG_FILE" | ./ffplay -i - -loglevel quiet &

FFMPEG_PID=$!
echo "FFmpeg PID: $FFMPEG_PID"

# Monitor decoder input
tail -f "$LOG_FILE" | grep --line-buffered -E "(DECODER INPUT|OUTPUT|SWITCH|Injecting|cached)" &
TAIL_PID=$!

echo ""
echo "Monitoring for 30 seconds..."
echo "Stop source 0 to trigger failover and watch the NAL sequence"
echo ""

sleep 30

# Cleanup
kill $TAIL_PID 2>/dev/null
kill $FFMPEG_PID 2>/dev/null
wait $FFMPEG_PID 2>/dev/null

echo ""
echo "Test complete. Analyzing decoder input around switch..."
echo ""

# Show decoder input around the switch
echo "=== Decoder Input Around Switch ==="
grep -B 5 -A 20 "SWITCHED: Source 0 → 1" "$LOG_FILE" | grep -E "(DECODER INPUT|OUTPUT|SWITCH|Injecting|cached)"
echo ""
echo "Full log: $LOG_FILE"
