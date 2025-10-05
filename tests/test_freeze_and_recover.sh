#!/bin/bash

# Test freeze-frame and recovery behavior
# 1. Start with source 0 (red)
# 2. Stop source 0 - should enter freeze-frame
# 3. Start source 1 (blue) - should auto-switch to source 1
# 4. Verify smooth recovery

LOG_FILE="/Users/yarontorbaty/Documents/Code/FFmpeg/freeze_recover_test.log"
rm -f "$LOG_FILE"

echo "Starting freeze-frame and recovery test..."
echo "1. Source 0 (red) will be active"
echo "2. Stop source 0 after 5 seconds"
echo "3. Source 1 (blue) should be detected as healthy"
echo "4. Auto-failover should switch to source 1"
echo ""

# Start FFmpeg in background
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

# Monitor logs in background
tail -f "$LOG_FILE" | grep --line-buffered -E "(FREEZE|SWITCH|healthy|unhealthy|AUTO-FAILOVER|Initialized)" &
TAIL_PID=$!

echo ""
echo "Monitoring for 30 seconds..."
echo "Watch for:"
echo "  - Source 0 marked unhealthy after ~500ms"
echo "  - Freeze-frame mode activated"
echo "  - Source 1 detected as healthy"
echo "  - Auto-failover to source 1"
echo ""

sleep 30

# Cleanup
kill $TAIL_PID 2>/dev/null
kill $FFMPEG_PID 2>/dev/null
wait $FFMPEG_PID 2>/dev/null

echo ""
echo "Test complete. Check $LOG_FILE for details."
echo ""
echo "Summary:"
grep -E "(FREEZE|SWITCH|AUTO-FAILOVER)" "$LOG_FILE" | tail -20
