#!/bin/bash
# Test streamselect runtime map changes with manual input

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
LOG_FILE="/tmp/streamselect_test.log"

echo "======================================================"
echo "  StreamSelect Runtime Map Change Test"
echo "======================================================"
echo ""

# Cleanup
pkill -9 ffmpeg 2>/dev/null || true
rm -f "$LOG_FILE"
sleep 1

echo "Starting FFmpeg in background..."
echo "Log file: $LOG_FILE"
echo ""

# Start FFmpeg, will run for 60 seconds
$FFMPEG_PATH \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local" \
    -f lavfi -i "color=red:size=320x240:rate=5" \
    -f lavfi -i "color=green:size=320x240:rate=5" \
    -f lavfi -i "color=blue:size=320x240:rate=5" \
    -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
    -map "[out]" \
    -t 60 \
    -f null - \
    > "$LOG_FILE" 2>&1 &

FFMPEG_PID=$!
echo "FFmpeg PID: $FFMPEG_PID"
sleep 2

# Check if running
if ! ps -p $FFMPEG_PID > /dev/null 2>&1; then
    echo "ERROR: FFmpeg died"
    cat "$LOG_FILE"
    exit 1
fi

echo ""
echo "FFmpeg is running. Checking initialization..."
grep -E "(MSwitch.*initialized|streamselect)" "$LOG_FILE" | head -10
echo ""

echo "=============================================="
echo "  Manual Test Instructions"
echo "=============================================="
echo ""
echo "1. Find the FFmpeg process terminal"
echo "2. Click on it to focus"
echo "3. Press '1' key"
echo "4. Come back here and press Enter"
echo ""
read -p "Press Enter after you've pressed '1' in FFmpeg terminal..."

echo ""
echo "Checking log for switch to source 1..."
echo "========================================"
grep -E "(Switch request|Switching from|mswitch_update_filter_map|StreamSelect.*parse_mapping|avfilter_process_command)" "$LOG_FILE" | tail -20
echo ""

echo "Press '2' in FFmpeg terminal, then press Enter here..."
read

echo ""
echo "Checking log for switch to source 2..."
echo "========================================"
grep -E "(Switch request|Switching from|mswitch_update_filter_map|StreamSelect.*parse_mapping|avfilter_process_command)" "$LOG_FILE" | tail -20
echo ""

# Kill FFmpeg
kill $FFMPEG_PID 2>/dev/null || true
wait $FFMPEG_PID 2>/dev/null || true

echo ""
echo "======================================================"
echo "  Analysis"
echo "======================================================"
echo ""

echo "All StreamSelect parse_mapping calls:"
grep "StreamSelect.*parse_mapping" "$LOG_FILE"
echo ""

echo "All avfilter_process_command calls:"
grep "avfilter_process_command returned" "$LOG_FILE"
echo ""

echo "Full log available at: $LOG_FILE"

