#!/bin/bash

# MSwitch Live Streaming - Real-time Interactive Control
# Uses zmq or direct filter commands for instant switching

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
BBB_FILE="/tmp/mswitch_demo/big_buck_bunny.mp4"

echo "============================================================"
echo "  🎬 MSwitch Real-time Interactive Demo"
echo "============================================================"
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
echo "  🔴 [0] Red Color"
echo "  🐰 [1] Big Buck Bunny Movie"
echo "  🔵 [2] Blue Color"
echo "  🟢 [3] Green Color"
echo ""
echo "This demo will automatically switch through all sources"
echo "to demonstrate real-time switching capabilities."
echo ""
echo "Starting in 3 seconds..."
sleep 3

# Create a complete timeline with many switches
cat > /tmp/mswitch_timeline.txt << 'EOF'
0.0 mswitch map 0;
5.0 mswitch map 1;
10.0 mswitch map 2;
15.0 mswitch map 3;
20.0 mswitch map 0;
25.0 mswitch map 1;
30.0 mswitch map 2;
35.0 mswitch map 3;
40.0 mswitch map 1;
45.0 mswitch map 0;
EOF

echo "▶️  Opening playback window..."
"${FFPLAY_PATH:-ffplay}" -i udp://127.0.0.1:12380 \
    -window_title "MSwitch Demo: Auto-switching every 5 seconds" \
    -fflags nobuffer -flags low_delay -framedrop \
    -loglevel warning &

FFPLAY_PID=$!
sleep 2

echo "▶️  Starting encoder with auto-switching..."
echo ""
echo "Timeline:"
echo "  0-5s:   🔴 Red"
echo "  5-10s:  🐰 Big Buck Bunny"
echo "  10-15s: 🔵 Blue"
echo "  15-20s: 🟢 Green"
echo "  20-25s: 🔴 Red"
echo "  25-30s: 🐰 Big Buck Bunny"
echo "  30-35s: 🔵 Blue"
echo "  35-40s: 🟢 Green"
echo "  40-45s: 🐰 Big Buck Bunny"
echo "  45-50s: 🔴 Red"
echo ""
echo "Watch the ffplay window for the switches!"
echo ""

"$FFMPEG_PATH" \
    -f lavfi -i "color=red:size=1280x720:rate=30" \
    -stream_loop -1 -re -i "$BBB_FILE" \
    -f lavfi -i "color=blue:size=1280x720:rate=30" \
    -f lavfi -i "color=green:size=1280x720:rate=30" \
    -filter_complex "[0:v]scale=1280:720,fps=30,format=yuv420p[red];
                     [1:v]scale=1280:720,fps=30,format=yuv420p[movie];
                     [2:v]scale=1280:720,fps=30,format=yuv420p[blue];
                     [3:v]scale=1280:720,fps=30,format=yuv420p[green];
                     [red][movie][blue][green]mswitch=inputs=4:map=0[switched];
                     [switched]sendcmd=f=/tmp/mswitch_timeline.txt[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -g 30 -keyint_min 30 -sc_threshold 0 \
    -b:v 4M -maxrate 4M -bufsize 8M \
    -pix_fmt yuv420p \
    -f mpegts udp://127.0.0.1:12380 \
    -t 50 \
    2>&1 | grep -E "(MSwitch|Switched)" &

FFMPEG_PID=$!

# Monitor progress
for i in {1..50}; do
    sleep 1
    if ! kill -0 $FFMPEG_PID 2>/dev/null; then
        break
    fi
    
    # Show progress indicator
    case $i in
        5) echo "  ⚡ Should have switched to Big Buck Bunny..." ;;
        10) echo "  ⚡ Should have switched to Blue..." ;;
        15) echo "  ⚡ Should have switched to Green..." ;;
        20) echo "  ⚡ Should have switched to Red..." ;;
        25) echo "  ⚡ Should have switched to Big Buck Bunny..." ;;
        30) echo "  ⚡ Should have switched to Blue..." ;;
        35) echo "  ⚡ Should have switched to Green..." ;;
        40) echo "  ⚡ Should have switched to Big Buck Bunny..." ;;
        45) echo "  ⚡ Should have switched to Red..." ;;
    esac
done

wait $FFMPEG_PID 2>/dev/null

# Cleanup
sleep 2
kill $FFPLAY_PID 2>/dev/null
rm -f /tmp/mswitch_timeline.txt

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    Demo Complete                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Did you see the switches between:"
echo "    🔴 Red → 🐰 Movie → 🔵 Blue → 🟢 Green?"
echo ""
echo "  If switching didn't work, the issue might be:"
echo "    • sendcmd filter timing issues"
echo "    • Need to check filter logs"
echo ""
echo "  Let me check the filter output above..."
echo ""

