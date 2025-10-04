#!/bin/bash

# Comprehensive Buffer Debugging Test
# This will show buffer sizes at various stages to identify where the 7s buffer accumulates

echo "=== MSwitch Buffer Debugging Test ==="
echo "This will show detailed buffer information to identify the 7s buffer source"

# Start UDP sources
echo "Starting UDP sources..."
ffmpeg -f lavfi -re -i "color=red:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='RED %{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 60 \
  -f mpegts udp://127.0.0.1:12350 &
RED_PID=$!

ffmpeg -f lavfi -re -i "color=green:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='GREEN %{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 60 \
  -f mpegts udp://127.0.0.1:12351 &
GREEN_PID=$!

ffmpeg -f lavfi -re -i "color=blue:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='BLUE %{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 60 \
  -f mpegts udp://127.0.0.1:12352 &
BLUE_PID=$!

sleep 3

echo ""
echo "=== Starting MSwitch with Buffer Debugging ==="
echo "Look for these debug messages:"
echo "- [FFmpeg] Input Buffer Debug: Shows input buffer sizes"
echo "- [MSwitch Filter] Buffer Debug: Shows filter buffer sizes"
echo "- [MSwitch Filter] Discarded X frames: Shows frame discarding"
echo ""

# MSwitch with comprehensive debugging
timeout 20s ./ffmpeg \
  -fflags nobuffer -flags low_delay \
  -analyzeduration 0 -probesize 32 -max_delay 0 \
  -flush_packets 1 \
  -loglevel info \
  -msw.enable -msw.sources "s0=local;s1=local;s2=local" \
  -msw.auto.enable -msw.auto.recovery_delay 2000 \
  -i "udp://127.0.0.1:12350?fifo_size=102400&overrun_nonfatal=1&timeout=1000000" \
  -i "udp://127.0.0.1:12351?fifo_size=102400&overrun_nonfatal=1&timeout=1000000" \
  -i "udp://127.0.0.1:12352?fifo_size=102400&overrun_nonfatal=1&timeout=1000000" \
  -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0,fps=30[out]" \
  -map "[out]" -c:v libx264 -r 30 -preset ultrafast -g 60 -keyint_min 1 -sc_threshold 0 \
  -pix_fmt yuv420p -f mpegts - | ffplay -fflags nobuffer -flags low_delay -i - -loglevel warning

echo ""
echo "=== Analysis ==="
echo "Check the debug output above for:"
echo "1. Input buffer sizes - are they growing?"
echo "2. Filter buffer sizes - are frames accumulating?"
echo "3. Frame discarding - is it working?"
echo "4. Timing - when does buffering start/stop?"

# Cleanup
cleanup() {
    echo "Cleaning up..."
    kill $RED_PID $GREEN_PID $BLUE_PID 2>/dev/null
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT
