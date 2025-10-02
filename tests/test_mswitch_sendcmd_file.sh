#!/bin/bash

# MSwitch Filter - File-based Command Control
# Dynamically update commands while FFmpeg is running

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
BBB_FILE="/tmp/mswitch_demo/big_buck_bunny.mp4"
CMD_FILE="/tmp/mswitch_commands_dynamic.txt"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      MSwitch Filter - File-based Command Control             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
rm -f "$CMD_FILE"
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
echo "  HOW TO CONTROL:"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Commands are sent via the sendcmd filter file:"
echo "  $CMD_FILE"
echo ""
echo "  In another terminal, add commands to switch:"
echo ""
echo "  echo \"10.0 mswitch map 1;\" >> $CMD_FILE"
echo "  echo \"15.0 mswitch map 2;\" >> $CMD_FILE"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Start with source 0 (red)
echo "0.0 mswitch map 0;" > "$CMD_FILE"

sleep 2

# Start ffplay
echo "▶️  Starting playback window..."
"${FFPLAY_PATH:-ffplay}" -i udp://127.0.0.1:12400 \
    -window_title "MSwitch Filter - File Command Control" \
    -fflags nobuffer -flags low_delay -framedrop \
    -loglevel warning &

FFPLAY_PID=$!
sleep 2

# Start FFmpeg with mswitch filter and sendcmd
echo "▶️  Starting encoder..."
"$FFMPEG_PATH" \
    -f lavfi -i "color=red:size=1280x720:rate=30" \
    -stream_loop -1 -re -i "$BBB_FILE" \
    -f lavfi -i "color=blue:size=1280x720:rate=30" \
    -f lavfi -i "color=green:size=1280x720:rate=30" \
    -filter_complex "[0:v]format=yuv420p[red];
                     [1:v]scale=1280:720,fps=30,format=yuv420p[movie];
                     [2:v]format=yuv420p[blue];
                     [3:v]format=yuv420p[green];
                     [red][movie][blue][green]mswitch=inputs=4:map=0[switched];
                     [switched]sendcmd=f=$CMD_FILE[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -g 30 -keyint_min 30 -sc_threshold 0 \
    -b:v 4M -maxrate 4M -bufsize 8M \
    -pix_fmt yuv420p \
    -f mpegts udp://127.0.0.1:12400 \
    -loglevel error &

FFMPEG_PID=$!

sleep 3

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        🔴 LIVE - File Command Control Active                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  FFmpeg is reading commands from:"
echo "  $CMD_FILE"
echo ""
echo "  Automatic demo starting..."
echo ""

# Automatic switching demo
for i in {1..20}; do
    sleep 2
    
    if ! kill -0 $FFMPEG_PID 2>/dev/null; then
        echo "FFmpeg stopped"
        break
    fi
    
    case $((i % 4)) in
        0)
            SOURCE=0
            NAME="Red"
            ;;
        1)
            SOURCE=1
            NAME="Movie"
            ;;
        2)
            SOURCE=2
            NAME="Blue"
            ;;
        3)
            SOURCE=3
            NAME="Green"
            ;;
    esac
    
    TIMESTAMP=$(echo "scale=1; $i * 2" | bc)
    echo "${TIMESTAMP} mswitch map ${SOURCE};" >> "$CMD_FILE"
    echo "  ⚡ [${i}/20] Switched to $NAME (timestamp: ${TIMESTAMP}s)"
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Automatic demo complete!"
echo "  Press Ctrl+C to stop."
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Keep running
wait $FFMPEG_PID

# Cleanup
kill $FFPLAY_PID 2>/dev/null
pkill -9 ffmpeg ffplay 2>/dev/null
rm -f "$CMD_FILE"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Session Complete                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  File-based command control allows you to:"
echo "    • Queue commands while stream is running"
echo "    • Control from scripts and automation"
echo "    • Schedule switches at specific timestamps"
echo "    • Integrate with external systems"
echo ""

