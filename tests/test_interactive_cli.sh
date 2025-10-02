#!/bin/bash
# Interactive CLI Testing Script
# Tests MSwitch filter-based switching using keyboard commands

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"

echo "======================================================"
echo "  MSwitch Interactive CLI Test"
echo "======================================================"
echo ""
echo "This test demonstrates filter-based source switching"
echo "using the interactive keyboard commands."
echo ""
echo "INSTRUCTIONS:"
echo "  1. An ffplay window will open showing a colored screen"
echo "  2. Click on the TERMINAL window (where FFmpeg is running)"
echo "  3. Press these keys to switch sources:"
echo "       '0' = Switch to RED"
echo "       '1' = Switch to GREEN"  
echo "       '2' = Switch to BLUE"
echo "       'm' = Show MSwitch status"
echo "       '?' = Show help"
echo "       'q' = Quit"
echo ""
echo "Expected behavior:"
echo "  - The ffplay window color should change immediately"
echo "  - Terminal shows: [MSwitch] Switching from source X to source Y"
echo ""
echo "Press Enter to start the test..."
read

# Cleanup
cleanup() {
    echo ""
    echo "Cleaning up..."
    pkill -9 ffmpeg 2>/dev/null || true
    pkill -9 ffplay 2>/dev/null || true
    exit 0
}

trap cleanup EXIT INT TERM
pkill -9 ffmpeg ffplay 2>/dev/null || true
sleep 1

echo ""
echo "======================================================"
echo "  Starting FFmpeg (WITHOUT webhook)"
echo "======================================================"
echo ""

# Start FFmpeg with MSwitch and filter-based switching, output to ffplay
$FFMPEG_PATH \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local" \
    -f lavfi -i "color=red:size=640x480:rate=10" \
    -f lavfi -i "color=green:size=640x480:rate=10" \
    -f lavfi -i "color=blue:size=640x480:rate=10" \
    -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -g 50 -pix_fmt yuv420p \
    -f mpegts - 2>&1 | ffplay -i - -loglevel warning &

FFMPEG_PID=$!
echo "FFmpeg started (PID: $FFMPEG_PID)"
echo ""
echo "======================================================"
echo "  Test Instructions"
echo "======================================================"
echo ""
echo "1. Make sure ffplay window is visible (showing RED)"
echo "2. Click on the TERMINAL (this window) to focus it"
echo "3. Press '1' key → Screen should turn GREEN"
echo "4. Press '2' key → Screen should turn BLUE"
echo "5. Press '0' key → Screen should turn RED"
echo "6. Press 'q' to quit when done"
echo ""
echo "NOTE: You must click the terminal window for keyboard"
echo "      input to be captured by FFmpeg!"
echo ""
echo "Waiting for FFmpeg to finish or for you to quit (q)..."
echo ""

# Wait for FFmpeg to finish
wait $FFMPEG_PID

echo ""
echo "======================================================"
echo "  Test Complete"
echo "======================================================"

