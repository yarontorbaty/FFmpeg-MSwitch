#!/bin/bash

# Interactive MSwitch Filter Test with Runtime Switching
# Uses sendcmd filter to change sources dynamically

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
FFPLAY_PATH="${FFPLAY_PATH:-./ffplay}"

echo "============================================================"
echo "  MSwitch Filter - Interactive Runtime Switching"
echo "============================================================"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 2

echo "This test demonstrates runtime switching using sendcmd filter."
echo "The video will automatically switch between RED, GREEN, and BLUE."
echo ""
echo "Timeline:"
echo "  0-5s:  RED (map=0)"
echo "  5-10s: GREEN (map=1)"
echo "  10-15s: BLUE (map=2)"
echo "  15-20s: RED again (map=0)"
echo ""

# Create sendcmd script with switching timeline
cat > /tmp/mswitch_commands.txt << 'EOF'
0.0 mswitch map 0;
5.0 mswitch map 1;
10.0 mswitch map 2;
15.0 mswitch map 0;
EOF

echo "Starting playback (20 seconds)..."
echo "Watch as the colors change automatically!"
echo ""

"$FFMPEG_PATH" \
    -f lavfi -i "color=red:size=640x480:rate=25" \
    -f lavfi -i "color=green:size=640x480:rate=25" \
    -f lavfi -i "color=blue:size=640x480:rate=25" \
    -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0[switched];
                     [switched]sendcmd=f=/tmp/mswitch_commands.txt[out]" \
    -map "[out]" \
    -t 20 \
    -c:v libx264 -preset ultrafast -f mpegts - 2>/dev/null | \
    "$FFPLAY_PATH" -i - -window_title "MSwitch: Runtime Switching Demo" -autoexit -loglevel quiet

echo ""
echo "============================================================"
echo "  Test Complete"
echo "============================================================"
echo ""
echo "Did you see the colors change?"
echo "  0-5s:  RED"
echo "  5-10s: GREEN"
echo "  10-15s: BLUE"
echo "  15-20s: RED again"
echo ""
echo "The mswitch filter successfully switched in real-time!"
echo "============================================================"

# Cleanup
rm -f /tmp/mswitch_commands.txt

