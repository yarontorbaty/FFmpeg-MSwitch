#!/bin/bash

# MSwitch Direct CLI Control
# Type 0/1/2/3 directly in the FFmpeg terminal window

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
BBB_FILE="/tmp/mswitch_demo/big_buck_bunny.mp4"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         🎮 MSwitch Direct CLI Control                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 2

# Check if Big Buck Bunny exists
if [ ! -f "$BBB_FILE" ]; then
    echo "📥 Big Buck Bunny not found, using colors only"
    BBB_FILE=""
fi

echo "This demo uses FFmpeg's built-in interactive CLI commands."
echo ""
echo "Available Sources:"
echo "  [0] 🔴 Red"
echo "  [1] 🟢 Green"
echo "  [2] 🔵 Blue"
if [ -n "$BBB_FILE" ]; then
    echo "  [3] 🐰 Big Buck Bunny"
    NB_SOURCES=4
else
    NB_SOURCES=3
fi
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Start ffplay first
echo "▶️  Starting playback window..."
"${FFPLAY_PATH:-ffplay}" -i udp://127.0.0.1:12420 \
    -window_title "MSwitch CLI Control - Type 0/1/2/3 in FFmpeg window" \
    -fflags nobuffer -flags low_delay \
    -loglevel warning &

FFPLAY_PID=$!
sleep 2

# Build source configuration
if [ -n "$BBB_FILE" ]; then
    SOURCES="s0=local;s1=local;s2=local;s3=local"
else
    SOURCES="s0=local;s1=local;s2=local"
fi

echo "▶️  Starting FFmpeg with MSwitch CLI enabled..."
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   🔴 FFmpeg is RUNNING                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  INTERACTIVE COMMANDS (type in this window):"
echo ""
echo "    0  →  Switch to Red"
echo "    1  →  Switch to Green"
echo "    2  →  Switch to Blue"
if [ -n "$BBB_FILE" ]; then
    echo "    3  →  Switch to Big Buck Bunny"
fi
echo "    m  →  Show MSwitch status"
echo "    q  →  Quit"
echo ""
echo "  Watch the ffplay window change as you type!"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Start FFmpeg with MSwitch enabled
if [ -n "$BBB_FILE" ]; then
    "$FFMPEG_PATH" \
        -msw.enable \
        -msw.sources "$SOURCES" \
        -msw.mode seamless \
        -f lavfi -i "color=red:size=1280x720:rate=30" \
        -f lavfi -i "color=green:size=1280x720:rate=30" \
        -f lavfi -i "color=blue:size=1280x720:rate=30" \
        -stream_loop -1 -re -i "$BBB_FILE" \
        -map 0:v -map 1:v -map 2:v -map 3:v \
        -c:v libx264 -preset ultrafast -tune zerolatency \
        -g 30 -keyint_min 30 -sc_threshold 0 \
        -b:v 4M -maxrate 4M -bufsize 8M \
        -pix_fmt yuv420p \
        -f mpegts udp://127.0.0.1:12420
else
    "$FFMPEG_PATH" \
        -msw.enable \
        -msw.sources "$SOURCES" \
        -msw.mode seamless \
        -f lavfi -i "color=red:size=1280x720:rate=30" \
        -f lavfi -i "color=green:size=1280x720:rate=30" \
        -f lavfi -i "color=blue:size=1280x720:rate=30" \
        -map 0:v -map 1:v -map 2:v \
        -c:v libx264 -preset ultrafast -tune zerolatency \
        -g 30 -keyint_min 30 -sc_threshold 0 \
        -b:v 4M -maxrate 4M -bufsize 8M \
        -pix_fmt yuv420p \
        -f mpegts udp://127.0.0.1:12420
fi

# Cleanup
kill $FFPLAY_PID 2>/dev/null
pkill -9 ffplay 2>/dev/null

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Session Complete                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  The direct CLI control lets you:"
echo "    • Type commands directly into FFmpeg terminal"
echo "    • See immediate switching feedback"
echo "    • No external files or scripts needed"
echo ""
echo "  This uses the legacy MSwitch context with frame-level"
echo "  filtering for visual switching."
echo ""

