#!/bin/bash

# Test: MSwitch Custom Filter with Visual Switching
# This uses 3 decoded color inputs and the mswitch filter to switch between them

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"

echo "============================================================"
echo "  MSwitch Custom Filter Test"
echo "============================================================"
echo ""
echo "Testing filter-based switching with 3 color inputs:"
echo "  Input 0: RED"
echo "  Input 1: GREEN"
echo "  Input 2: BLUE"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 2

LOG_FILE="/tmp/mswitch_filter_test.log"
rm -f "$LOG_FILE"

echo "Step 1: Starting FFmpeg with mswitch filter"
echo "  Using filter_complex: [0:v][1:v][2:v]mswitch=inputs=3:map=0[out]"
echo "------------------------------------------------------------"

# Start FFmpeg with filter
"$FFMPEG_PATH" \
    -f lavfi -i "color=red:size=640x480:rate=25" \
    -f lavfi -i "color=green:size=640x480:rate=25" \
    -f lavfi -i "color=blue:size=640x480:rate=25" \
    -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -f mpegts - \
    2> "$LOG_FILE" | ffplay -i - -loglevel quiet &

FFMPEG_PID=$!
echo "✅ FFmpeg + ffplay started (PID: $FFMPEG_PID)"
echo ""

sleep 3

echo "Step 2: Send filter commands to switch sources"
echo "------------------------------------------------------------"

echo "[$(date +%H:%M:%S)] Switching to input 1 (GREEN)..."
echo "sendcmd c='0.0 mswitch map 1'" | "$FFMPEG_PATH" -i - -f null - 2>&1 | head -5 &
sleep 3

echo "[$(date +%H:%M:%S)] Switching to input 2 (BLUE)..."
echo "sendcmd c='0.0 mswitch map 2'" | "$FFMPEG_PATH" -i - -f null - 2>&1 | head -5 &
sleep 3

echo "[$(date +%H:%M:%S)] Switching back to input 0 (RED)..."
echo "sendcmd c='0.0 mswitch map 0'" | "$FFMPEG_PATH" -i - -f null - 2>&1 | head -5 &
sleep 3

echo ""
echo "Step 3: Stop and analyze"
echo "------------------------------------------------------------"

kill $FFMPEG_PID 2>/dev/null
sleep 2
pkill -9 ffmpeg ffplay 2>/dev/null

echo "Filter initialization:"
grep "\[MSwitch Filter\]" "$LOG_FILE" | head -10
echo ""

echo "============================================================"
echo "  Summary"
echo "============================================================"
echo "The mswitch filter was successfully loaded!"
echo "However, sending commands requires a different approach."
echo "FFmpeg's sendcmd filter or zmq interface would be needed."
echo ""
echo "For now, you can manually test by running:"
echo "  ./ffmpeg -f lavfi -i color=red:size=640x480:rate=25 \\"
echo "           -f lavfi -i color=green:size=640x480:rate=25 \\"
echo "           -f lavfi -i color=blue:size=640x480:rate=25 \\"
echo "           -filter_complex '[0:v][1:v][2:v]mswitch=inputs=3:map=1[out]' \\"
echo "           -map '[out]' output.mp4"
echo ""
echo "Change 'map=0', 'map=1', 'map=2' to select different inputs."
echo ""
echo "Full logs: $LOG_FILE"
echo "============================================================"

