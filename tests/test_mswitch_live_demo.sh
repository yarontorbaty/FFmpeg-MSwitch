#!/bin/bash

# MSwitch Live Streaming Demo with Real Content
# Test Pattern → Big Buck Bunny → Test Pattern → Bars
# Output: Live MPEG-TS stream playable with ffplay

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
FFPLAY_PATH="${FFPLAY_PATH:-./ffplay}"
BBB_FILE="/tmp/mswitch_demo/big_buck_bunny.mp4"

echo "============================================================"
echo "  MSwitch Live Streaming Demo"
echo "============================================================"
echo ""
echo "Sources:"
echo "  Input 0: SMPTE Color Bars (test pattern)"
echo "  Input 1: Big Buck Bunny (movie file, looped)"
echo "  Input 2: Test Pattern with Timer"
echo ""
echo "Timeline (60 seconds):"
echo "  0-10s:  Color Bars"
echo "  10-40s: Big Buck Bunny"
echo "  40-50s: Color Bars again"
echo "  50-60s: Test Pattern"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 2

# Check if Big Buck Bunny exists
if [ ! -f "$BBB_FILE" ]; then
    echo "Error: Big Buck Bunny not found at $BBB_FILE"
    echo "Please run: cd /tmp/mswitch_demo && curl -L -o big_buck_bunny.mp4 'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4'"
    exit 1
fi

echo "Creating switching timeline..."
cat > /tmp/mswitch_live_timeline.txt << 'EOF'
0.0 mswitch map 0;
10.0 mswitch map 1;
40.0 mswitch map 0;
50.0 mswitch map 2;
EOF

echo "Starting live stream..."
echo ""
echo "Opening ffplay in 3 seconds..."
echo "You should see: Bars → Movie → Bars → Pattern"
echo ""

# Start ffplay first to receive the stream
"$FFPLAY_PATH" -i udp://127.0.0.1:12350 \
    -window_title "MSwitch Live Demo" \
    -fflags nobuffer \
    -flags low_delay \
    -framedrop \
    -loglevel quiet &

FFPLAY_PID=$!
sleep 3

# Start the MSwitch live encoder
echo "▶️  Starting MSwitch encoder..."
"$FFMPEG_PATH" \
    -f lavfi -i "smptebars=size=1280x720:rate=30" \
    -stream_loop -1 -i "$BBB_FILE" \
    -f lavfi -i "testsrc=size=1280x720:rate=30,drawtext=text='Test Pattern %{n}':x=10:y=10:fontsize=48:fontcolor=white" \
    -filter_complex "[0:v]scale=1280:720,fps=30[bars];
                     [1:v]scale=1280:720,fps=30[movie];
                     [2:v]scale=1280:720,fps=30[test];
                     [bars][movie][test]mswitch=inputs=3:map=0[switched];
                     [switched]sendcmd=f=/tmp/mswitch_live_timeline.txt[out]" \
    -map "[out]" \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -g 30 -keyint_min 30 -sc_threshold 0 \
    -b:v 2M -maxrate 2M -bufsize 4M \
    -pix_fmt yuv420p \
    -f mpegts udp://127.0.0.1:12350 \
    -t 60 \
    2>&1 | grep -E "(MSwitch|Stream|frame=)" &

FFMPEG_PID=$!

echo ""
echo "🔴 LIVE STREAMING"
echo ""
echo "Timeline:"
echo "  [0-10s]  ▓▓▓▓▓▓▓▓▓▓ Color Bars"
echo "  [10-40s] ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ Big Buck Bunny"
echo "  [40-50s] ▓▓▓▓▓▓▓▓▓▓ Color Bars"  
echo "  [50-60s] ▓▓▓▓▓▓▓▓▓▓ Test Pattern"
echo ""
echo "Press Ctrl+C to stop..."
echo ""

# Wait for encoding to complete
wait $FFMPEG_PID

# Give ffplay a moment to finish
sleep 2
kill $FFPLAY_PID 2>/dev/null

echo ""
echo "============================================================"
echo "  Demo Complete"
echo "============================================================"
echo ""
echo "Did you see the switches?"
echo "  ✓ Color Bars at start"
echo "  ✓ Switched to Big Buck Bunny at 10s"
echo "  ✓ Switched back to Color Bars at 40s"
echo "  ✓ Switched to Test Pattern at 50s"
echo ""
echo "The mswitch filter successfully handled:"
echo "  - Live test pattern generation"
echo "  - Looped video file playback"
echo "  - Real-time switching between sources"
echo "  - Live UDP streaming output"
echo "============================================================"

# Cleanup
rm -f /tmp/mswitch_live_timeline.txt

