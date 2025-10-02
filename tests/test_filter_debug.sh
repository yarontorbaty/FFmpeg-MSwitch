#!/bin/bash
# Test filter-based switching with detailed debugging

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"

echo "======================================================"
echo "  Filter-based Switching Debug Test"
echo "======================================================"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null || true
sleep 1

LOG_FILE="/tmp/mswitch_filter_debug.log"
rm -f "$LOG_FILE"

echo "Starting FFmpeg (output to $LOG_FILE)..."
echo "This will run for 30 seconds with automatic switches."
echo ""

# Start FFmpeg in background, log to file
timeout 30 $FFMPEG_PATH \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local" \
    -f lavfi -i "color=red:size=320x240:rate=10" \
    -f lavfi -i "color=green:size=320x240:rate=10" \
    -f lavfi -i "color=blue:size=320x240:rate=10" \
    -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
    -map "[out]" \
    -t 30 \
    -f null - \
    > "$LOG_FILE" 2>&1 &

FFMPEG_PID=$!
echo "FFmpeg started (PID: $FFMPEG_PID)"
sleep 2

# Check if it's running
if ! ps -p $FFMPEG_PID > /dev/null 2>&1; then
    echo "ERROR: FFmpeg died immediately"
    echo "=== Last 50 lines of log ==="
    tail -50 "$LOG_FILE"
    exit 1
fi

echo ""
echo "FFmpeg is running. Checking initialization..."
sleep 1

# Show initialization
echo "=== Initialization Log ==="
grep -E "(MSwitch|streamselect|Filter)" "$LOG_FILE" | head -30
echo ""

# Simulate keyboard input by sending signals
echo "Simulating source switches..."
echo ""

echo "[5s] Switching to source 1 (GREEN) via echo to stdin..."
sleep 3
echo "1" > /proc/$FFMPEG_PID/fd/0 2>/dev/null || echo "Cannot write to stdin (process might not support it)"
sleep 2

echo "[10s] Checking for switch messages..."
grep -E "(>>> mswitch_update_filter_map|av_opt_set returned|Filter updated)" "$LOG_FILE" | tail -10
echo ""

echo "[12s] Switching to source 2 (BLUE)..."
sleep 2
echo "2" > /proc/$FFMPEG_PID/fd/0 2>/dev/null || echo "Cannot write to stdin"
sleep 2

echo "[15s] Checking for switch messages..."
grep -E "(>>> mswitch_update_filter_map|av_opt_set returned|Filter updated)" "$LOG_FILE" | tail -10
echo ""

echo "Waiting for FFmpeg to finish (or timeout)..."
wait $FFMPEG_PID 2>/dev/null

echo ""
echo "======================================================"
echo "  Final Analysis"
echo "======================================================"
echo ""

echo "=== All Filter Update Attempts ==="
grep -E "(>>> mswitch_update_filter_map|av_opt_set returned|Filter updated)" "$LOG_FILE"
echo ""

echo "=== All Switch Requests ==="
grep -E "(Switch request:|Switching from source)" "$LOG_FILE"
echo ""

echo "Full log saved to: $LOG_FILE"
echo "View with: less $LOG_FILE"

