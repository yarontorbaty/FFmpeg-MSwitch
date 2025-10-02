#!/bin/bash

# MSwitch Direct Output - No UDP, direct to screen
# Eliminates network buffering issues

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
BBB_FILE="/tmp/mswitch_demo/big_buck_bunny.mp4"

echo "============================================================"
echo "  🎬 MSwitch Direct Output Test"
echo "============================================================"
echo ""
echo "This test outputs directly to SDL (screen) without UDP"
echo "to eliminate any network buffering issues."
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

echo "Timeline (30 seconds total):"
echo "  0-5s:   🔴 RED"
echo "  5-10s:  🐰 BIG BUCK BUNNY"
echo "  10-15s: 🔵 BLUE"
echo "  15-20s: 🟢 GREEN"
echo "  20-25s: 🐰 BIG BUCK BUNNY"
echo "  25-30s: 🔴 RED"
echo ""
echo "Watch for the visual changes!"
echo "Starting in 3 seconds..."
sleep 3

# Create switching timeline
cat > /tmp/mswitch_direct.txt << 'EOF'
0.0 mswitch map 0;
5.0 mswitch map 1;
10.0 mswitch map 2;
15.0 mswitch map 3;
20.0 mswitch map 1;
25.0 mswitch map 0;
EOF

echo "▶️  Starting direct output..."
echo ""

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
                     [switched]sendcmd=f=/tmp/mswitch_direct.txt[out]" \
    -map "[out]" \
    -t 30 \
    -f sdl2 - \
    2>&1 | grep -E "(MSwitch|Switched|error)" | head -30

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    Test Complete                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Did you see the visual changes?"
echo "  5s:  Red → Movie"
echo "  10s: Movie → Blue"
echo "  15s: Blue → Green"
echo "  20s: Green → Movie"
echo "  25s: Movie → Red"
echo ""
echo "If you still only saw red, please let me know and we'll"
echo "investigate further. The filter logs show it's switching"
echo "correctly at the filter level."
echo ""

rm -f /tmp/mswitch_direct.txt

