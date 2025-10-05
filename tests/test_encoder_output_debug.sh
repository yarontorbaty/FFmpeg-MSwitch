#!/bin/bash

# Test to verify packets from failover sources are reaching the encoder
# This will show detailed logging of:
# 1. Which source each packet comes from
# 2. Whether we're in freeze-frame mode
# 3. Whether we're waiting for I-frames from pending sources
# 4. Health status of all sources

LOG_FILE="/Users/yarontorbaty/Documents/Code/FFmpeg/encoder_output_debug.log"
rm -f "$LOG_FILE"

echo "Starting encoder output debug test..."
echo "This will show detailed packet flow from sources to encoder"
echo ""
echo "Watch for:"
echo "  - 'OUTPUT' messages showing which source is sending to encoder"
echo "  - 'PENDING SWITCH' messages when attempting to read from failover source"
echo "  - 'FREEZE-FRAME' type when repeating last good frame"
echo "  - Health status changes"
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

# Monitor specific log patterns
tail -f "$LOG_FILE" | grep --line-buffered -E "(OUTPUT|PENDING|FREEZE|SWITCH|healthy|unhealthy|AUTO-FAILOVER)" &
TAIL_PID=$!

echo ""
echo "Monitoring for 30 seconds..."
echo "Stop source 0 to trigger failover and watch the packet flow"
echo ""

sleep 30

# Cleanup
kill $TAIL_PID 2>/dev/null
kill $FFMPEG_PID 2>/dev/null
wait $FFMPEG_PID 2>/dev/null

echo ""
echo "Test complete. Analyzing results..."
echo ""

# Show summary
echo "=== Packet Output Summary ==="
grep "OUTPUT" "$LOG_FILE" | head -20
echo ""
echo "=== Switch Events ==="
grep -E "(SWITCH|AUTO-FAILOVER)" "$LOG_FILE"
echo ""
echo "=== Health Changes ==="
grep -E "(unhealthy|recovered)" "$LOG_FILE"
echo ""
echo "Full log: $LOG_FILE"
