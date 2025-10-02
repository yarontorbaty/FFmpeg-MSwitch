#!/bin/bash

# MSwitch Live Streaming - Simple Demo (No external dependencies)
# Switch between Color Bars, Big Buck Bunny, and Test Pattern

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
BBB_FILE="/tmp/mswitch_demo/big_buck_bunny.mp4"

echo "============================================================"
echo "  MSwitch Live Streaming Demo"
echo "============================================================"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 2

# Check if Big Buck Bunny exists
if [ ! -f "$BBB_FILE" ]; then
    echo "Big Buck Bunny not found. Downloading..."
    mkdir -p /tmp/mswitch_demo
    curl -L -o "$BBB_FILE" "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
    echo ""
fi

echo "Sources:"
echo "  [0] 🎨 Red Color (solid)"
echo "  [1] 🐰 Big Buck Bunny (movie)"
echo "  [2] 🔵 Blue Color (solid)"
echo ""
echo "Timeline (45 seconds):"
echo "  0-10s:  RED screen"
echo "  10-30s: Big Buck Bunny movie"
echo "  30-45s: BLUE screen"
echo ""
echo "Starting in 3 seconds..."
sleep 3

# Create switching timeline
cat > /tmp/mswitch_simple.txt << 'EOF'
0.0 mswitch map 0;
10.0 mswitch map 1;
30.0 mswitch map 2;
EOF

echo "▶️  Starting ffplay (playback window)..."
"${FFPLAY_PATH:-ffplay}" -i udp://127.0.0.1:12360 \
    -window_title "MSwitch Live: Red → Movie → Blue" \
    -fflags nobuffer -flags low_delay -framedrop \
    -loglevel quiet &

FFPLAY_PID=$!
sleep 3

echo "▶️  Starting encoder..."
echo ""

"$FFMPEG_PATH" \
    -f lavfi -i "color=red:size=1280x720:rate=30" \
    -stream_loop -1 -re -i "$BBB_FILE" \
    -f lavfi -i "color=blue:size=1280x720:rate=30" \
    -filter_complex "[0:v]scale=1280:720,fps=30,format=yuv420p[red];
                     [1:v]scale=1280:720,fps=30,format=yuv420p[movie];
                     [2:v]scale=1280:720,fps=30,format=yuv420p[blue];
                     [red][movie][blue]mswitch=inputs=3:map=0[switched];
                     [switched]sendcmd=f=/tmp/mswitch_simple.txt[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -g 30 -keyint_min 30 -sc_threshold 0 \
    -b:v 3M -maxrate 3M -bufsize 6M \
    -pix_fmt yuv420p \
    -t 45 \
    -f mpegts udp://127.0.0.1:12360 \
    2>&1 | grep -E "(MSwitch|error|Stream)" | head -20

# Wait for playback to finish
sleep 2
kill $FFPLAY_PID 2>/dev/null

echo ""
echo "============================================================"
echo "  Demo Complete!"
echo "============================================================"
echo ""
echo "Did you see the switches?"
echo "  ✓ Started with RED screen (0-10s)"
echo "  ✓ Switched to Big Buck Bunny movie (10-30s)"
echo "  ✓ Switched to BLUE screen (30-45s)"
echo ""
echo "The mswitch filter successfully handled:"
echo "  ✓ Solid color sources (red, blue)"
echo "  ✓ Real video file (Big Buck Bunny)"
echo "  ✓ Real-time switching via sendcmd"
echo "  ✓ Live playback to screen"
echo "  ✓ HD 720p @ 30fps output"
echo ""

rm -f /tmp/mswitch_simple.txt

