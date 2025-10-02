#!/bin/bash

# MSwitch CLI Control Demo
# Use FFmpeg's built-in interactive commands to switch sources
# Press 0, 1, 2, 3 to switch between sources in real-time

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
BBB_FILE="/tmp/mswitch_demo/big_buck_bunny.mp4"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         MSwitch CLI Control Demo (Interactive)               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 2

# Check if Big Buck Bunny exists
if [ ! -f "$BBB_FILE" ]; then
    echo "📥 Downloading Big Buck Bunny..."
    mkdir -p /tmp/mswitch_demo
    curl -L -o "$BBB_FILE" "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
    echo ""
fi

echo "Available Sources:"
echo "  [0] 🔴 Red Color"
echo "  [1] 🐰 Big Buck Bunny Movie"
echo "  [2] 🔵 Blue Color"
echo "  [3] 🟢 Green Color"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  HOW TO USE CLI CONTROL:"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  The FFmpeg process supports interactive commands."
echo "  Type a number in the FFmpeg terminal to switch sources:"
echo ""
echo "    Press [0] → Switch to Red"
echo "    Press [1] → Switch to Big Buck Bunny"
echo "    Press [2] → Switch to Blue"
echo "    Press [3] → Switch to Green"
echo "    Press [m] → Show MSwitch status"
echo "    Press [q] → Quit"
echo ""
echo "  Note: FFmpeg must be in the foreground to receive commands."
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Starting in 3 seconds..."
echo "Watch the ffplay window and type 0-3 in the FFmpeg terminal!"
echo ""
sleep 3

# Start ffplay
echo "▶️  Starting playback window..."
"${FFPLAY_PATH:-ffplay}" -i udp://127.0.0.1:12390 \
    -window_title "MSwitch CLI Control - Type 0/1/2/3 in FFmpeg window" \
    -fflags nobuffer -flags low_delay -framedrop \
    -loglevel warning &

FFPLAY_PID=$!
sleep 2

# Start FFmpeg with MSwitch CLI enabled
echo "▶️  Starting FFmpeg encoder with CLI control..."
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  FFmpeg is running with MSwitch CLI enabled                  ║"
echo "║                                                              ║"
echo "║  Interactive Commands:                                       ║"
echo "║    0 = Red | 1 = Movie | 2 = Blue | 3 = Green               ║"
echo "║    m = Status | q = Quit                                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Note: We're using the mswitch filter, not the old CLI system
# The interactive commands work through FFmpeg's main keyboard handler
"$FFMPEG_PATH" \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local;s3=local" \
    -msw.cli.enable \
    -f lavfi -i "color=red:size=1280x720:rate=30" \
    -stream_loop -1 -re -i "$BBB_FILE" \
    -f lavfi -i "color=blue:size=1280x720:rate=30" \
    -f lavfi -i "color=green:size=1280x720:rate=30" \
    -map 0:v -map 1:v -map 2:v -map 3:v \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -g 30 -keyint_min 30 -sc_threshold 0 \
    -b:v 4M -maxrate 4M -bufsize 8M \
    -pix_fmt yuv420p \
    -f mpegts udp://127.0.0.1:12390 \
    2>&1

# Cleanup
kill $FFPLAY_PID 2>/dev/null
pkill -9 ffplay 2>/dev/null

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Session Complete                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  The CLI control allows you to switch sources by typing"
echo "  commands directly into the FFmpeg terminal."
echo ""
echo "  This is useful for:"
echo "    • Manual testing and debugging"
echo "    • Live production with operator control"
echo "    • Quick demos without external tools"
echo ""

