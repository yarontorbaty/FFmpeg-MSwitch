#!/bin/bash
# Test the critical fix: using avfilter_process_command for runtime switching

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"

echo "======================================================"
echo "  CRITICAL FIX TEST: avfilter_process_command()"
echo "======================================================"
echo ""
echo "This test verifies that visual switching now works"
echo "after fixing the filter command API usage."
echo ""
echo "WHAT TO EXPECT:"
echo "  - ffplay window opens with RED screen"
echo "  - Terminal shows detailed debugging"
echo "  - Pressing '1' switches to GREEN (visual + logs)"
echo "  - Pressing '2' switches to BLUE (visual + logs)"
echo "  - Pressing '0' switches back to RED"
echo ""
echo "Press Enter to start..."
read

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null || true
sleep 1

echo ""
echo "Starting FFmpeg..."
echo "=========================================="
echo ""

$FFMPEG_PATH \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local" \
    -f lavfi -i "color=red:size=640x480:rate=10" \
    -f lavfi -i "color=green:size=640x480:rate=10" \
    -f lavfi -i "color=blue:size=640x480:rate=10" \
    -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -g 50 -pix_fmt yuv420p \
    -f mpegts - 2>&1 | ffplay -i - -loglevel warning

echo ""
echo "======================================================"
echo "  Test Complete"
echo "======================================================"
echo ""
echo "DID THE COLORS CHANGE WHEN YOU PRESSED KEYS?"
echo "  - If YES: The fix worked! Filter-based switching is validated."
echo "  - If NO: Check the debugging output above for errors."
echo ""

