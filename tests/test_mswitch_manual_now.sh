#!/bin/bash

# MSwitch Manual Control - Try It Now!
# Simple script for immediate manual testing

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
BBB_FILE="/tmp/mswitch_demo/big_buck_bunny.mp4"
CMD_FILE="/tmp/mswitch_manual_now.txt"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         🎮 MSwitch Manual Control - Try It Now!              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
rm -f "$CMD_FILE"
sleep 1

# Check if Big Buck Bunny exists
if [ ! -f "$BBB_FILE" ]; then
    echo "Big Buck Bunny not found. Using only color sources."
    BBB_FILE=""
fi

echo "Available Sources:"
echo "  [0] 🔴 Red"
echo "  [1] 🟢 Green"
echo "  [2] 🔵 Blue"
if [ -n "$BBB_FILE" ]; then
    echo "  [3] 🐰 Big Buck Bunny"
fi
echo ""

# Create initial command file
echo "0.0 mswitch map 0;" > "$CMD_FILE"

# Start ffplay first
echo "Starting playback window..."
"${FFPLAY_PATH:-ffplay}" -i udp://127.0.0.1:12410 \
    -window_title "MSwitch Manual Control" \
    -fflags nobuffer -flags low_delay \
    -loglevel error &

FFPLAY_PID=$!
sleep 2

# Build FFmpeg command based on available sources
if [ -n "$BBB_FILE" ]; then
    INPUTS="-f lavfi -i 'color=red:size=1280x720:rate=30' \
            -f lavfi -i 'color=green:size=1280x720:rate=30' \
            -f lavfi -i 'color=blue:size=1280x720:rate=30' \
            -stream_loop -1 -re -i '$BBB_FILE'"
    FILTER="[0:v]format=yuv420p[s0];
            [1:v]format=yuv420p[s1];
            [2:v]format=yuv420p[s2];
            [3:v]scale=1280:720,fps=30,format=yuv420p[s3];
            [s0][s1][s2][s3]mswitch=inputs=4:map=0[sw];
            [sw]sendcmd=f=$CMD_FILE[out]"
else
    INPUTS="-f lavfi -i 'color=red:size=1280x720:rate=30' \
            -f lavfi -i 'color=green:size=1280x720:rate=30' \
            -f lavfi -i 'color=blue:size=1280x720:rate=30'"
    FILTER="[0:v]format=yuv420p[s0];
            [1:v]format=yuv420p[s1];
            [2:v]format=yuv420p[s2];
            [s0][s1][s2]mswitch=inputs=3:map=0[sw];
            [sw]sendcmd=f=$CMD_FILE[out]"
fi

# Start FFmpeg encoder in background
eval "$FFMPEG_PATH" \
    $INPUTS \
    -filter_complex \"$FILTER\" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -g 30 -keyint_min 30 -sc_threshold 0 \
    -b:v 4M -maxrate 4M -bufsize 8M \
    -pix_fmt yuv420p \
    -f mpegts udp://127.0.0.1:12410 \
    -loglevel error 2>&1 | grep -i mswitch &

FFMPEG_PID=$!
sleep 2

# Check if FFmpeg started successfully
if ! kill -0 $FFMPEG_PID 2>/dev/null; then
    echo "❌ FFmpeg failed to start"
    kill $FFPLAY_PID 2>/dev/null
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                🔴 LIVE - Manual Control                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Current source: RED (0)"
echo ""
echo "  TO SWITCH SOURCES, use these commands in THIS terminal:"
echo ""
if [ -n "$BBB_FILE" ]; then
    echo "    0    Switch to Red"
    echo "    1    Switch to Green"
    echo "    2    Switch to Blue"
    echo "    3    Switch to Big Buck Bunny"
else
    echo "    0    Switch to Red"
    echo "    1    Switch to Green"
    echo "    2    Switch to Blue"
fi
echo "    q    Quit"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

TIMESTAMP=1.0

# Interactive loop
while true; do
    read -n 1 -s -p "Switch to source (0-3, q=quit): " KEY
    echo ""
    
    case "$KEY" in
        0|1|2|3)
            # Append switch command with incrementing timestamp
            echo "${TIMESTAMP} mswitch map ${KEY};" >> "$CMD_FILE"
            TIMESTAMP=$(echo "$TIMESTAMP + 0.1" | bc)
            
            case "$KEY" in
                0) NAME="🔴 Red" ;;
                1) NAME="🟢 Green" ;;
                2) NAME="🔵 Blue" ;;
                3) NAME="🐰 Big Buck Bunny" ;;
            esac
            
            echo "  ⚡ Switched to $NAME (source $KEY)"
            echo ""
            ;;
        q|Q)
            echo "  Stopping..."
            break
            ;;
        *)
            echo "  Invalid key. Use 0-3 or q"
            echo ""
            ;;
    esac
    
    # Check if FFmpeg is still running
    if ! kill -0 $FFMPEG_PID 2>/dev/null; then
        echo "❌ FFmpeg stopped"
        break
    fi
done

# Cleanup
echo ""
echo "Cleaning up..."
kill $FFMPEG_PID 2>/dev/null
kill $FFPLAY_PID 2>/dev/null
sleep 1
pkill -9 ffmpeg ffplay 2>/dev/null
rm -f "$CMD_FILE"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Manual control session complete!"
echo "═══════════════════════════════════════════════════════════════"
echo ""

