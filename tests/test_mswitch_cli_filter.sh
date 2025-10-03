#!/bin/bash

# MSwitch CLI Control - Using mswitch Filter
# Type 0/1/2/3 directly in FFmpeg terminal to control the filter

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
BBB_FILE="/tmp/mswitch_demo/big_buck_bunny.mp4"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║    🎮 MSwitch CLI → Filter Control (Production Ready!)       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 2

# Check if Big Buck Bunny exists
if [ ! -f "$BBB_FILE" ]; then
    echo "Big Buck Bunny not found, using colors only"
    BBB_FILE=""
fi

echo "This uses the mswitch filter (the one that works!)"
echo "CLI commands send avfilter_process_command() to the filter."
echo ""
echo "Available Sources:"
echo "  [0] 🔴 Red"
echo "  [1] 🟢 Green"
echo "  [2] 🔵 Blue"
if [ -n "$BBB_FILE" ]; then
    echo "  [3] 🐰 Big Buck Bunny"
fi
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Start ffplay
echo "▶️  Starting playback window..."
"${FFPLAY_PATH:-ffplay}" -i udp://127.0.0.1:12430 \
    -window_title "MSwitch CLI + Filter - Type 0/1/2/3" \
    -fflags nobuffer -flags low_delay \
    -loglevel warning &

FFPLAY_PID=$!
sleep 2

echo "▶️  Starting FFmpeg with mswitch filter..."
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              🔴 FFmpeg RUNNING - Type Here!                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  INTERACTIVE COMMANDS:"
echo ""
echo "    0  →  Red"
echo "    1  →  Green"
echo "    2  →  Blue"
if [ -n "$BBB_FILE" ]; then
    echo "    3  →  Big Buck Bunny"
fi
echo "    q  →  Quit"
echo ""
echo "  Press keys and watch the ffplay window change!"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Build FFmpeg command with mswitch filter
# Note: Don't use -re on lavfi inputs, they generate at the requested rate
if [ -n "$BBB_FILE" ]; then
    "$FFMPEG_PATH" \
        -f lavfi -i "color=red:size=1280x720:rate=30" \
        -f lavfi -i "color=green:size=1280x720:rate=30" \
        -f lavfi -i "color=blue:size=1280x720:rate=30" \
        -stream_loop -1 -re -i "$BBB_FILE" \
        -filter_complex "[0:v]format=yuv420p[s0];
                         [1:v]format=yuv420p[s1];
                         [2:v]format=yuv420p[s2];
                         [3:v]scale=1280:720,fps=30,format=yuv420p[s3];
                         [s0][s1][s2][s3]mswitch=inputs=4:map=0[out]" \
        -map "[out]" \
        -c:v libx264 -preset ultrafast -tune zerolatency \
        -g 1 -keyint_min 1 -sc_threshold 0 \
        -b:v 2M -maxrate 2M -bufsize 2M \
        -pix_fmt yuv420p \
        -vsync cfr \
        -f mpegts udp://127.0.0.1:12430?pkt_size=1316
else
    "$FFMPEG_PATH" \
        -f lavfi -i "color=red:size=1280x720:rate=30" \
        -f lavfi -i "color=green:size=1280x720:rate=30" \
        -f lavfi -i "color=blue:size=1280x720:rate=30" \
        -filter_complex "[0:v]format=yuv420p[s0];
                         [1:v]format=yuv420p[s1];
                         [2:v]format=yuv420p[s2];
                         [s0][s1][s2]mswitch=inputs=3:map=0[out]" \
        -map "[out]" \
        -c:v libx264 -preset ultrafast -tune zerolatency \
        -g 1 -keyint_min 1 -sc_threshold 0 \
        -b:v 2M -maxrate 2M -bufsize 2M \
        -pix_fmt yuv420p \
        -vsync cfr \
        -f mpegts udp://127.0.0.1:12430?pkt_size=1316
fi

# Cleanup
kill $FFPLAY_PID 2>/dev/null
pkill -9 ffplay 2>/dev/null

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Session Complete                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  ✅ This approach works because:"
echo "     • Uses the mswitch filter (production-ready)"
echo "     • CLI sends avfilter_process_command() directly"
echo "     • No scheduler filtering needed"
echo "     • Same technology as sendcmd demos"
echo ""
echo "  The best of both worlds:"
echo "     • Interactive CLI control"
echo "     • Reliable filter-based switching"
echo ""

