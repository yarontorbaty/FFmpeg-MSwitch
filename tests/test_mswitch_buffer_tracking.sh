#!/bin/bash

# Comprehensive Buffer Tracking Test
# This script adds detailed buffer tracking across the entire pipeline

echo "=== MSwitch Buffer Tracking Test ==="
echo "This test adds comprehensive buffer tracking to identify where 6s buffer comes from"
echo ""

# Start UDP sources
echo "Starting UDP sources..."
ffmpeg -f lavfi -re -i "color=red:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='RED %{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 30 -keyint_min 1 -sc_threshold 0 \
  -f mpegts udp://127.0.0.1:12350 &
RED_PID=$!

ffmpeg -f lavfi -re -i "color=green:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='GREEN %{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 30 -keyint_min 1 -sc_threshold 0 \
  -f mpegts udp://127.0.0.1:12351 &
GREEN_PID=$!

ffmpeg -f lavfi -re -i "color=blue:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='BLUE %{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 30 -keyint_min 1 -sc_threshold 0 \
  -f mpegts udp://127.0.0.1:12352 &
BLUE_PID=$!

sleep 3

echo ""
echo "=== BUFFER TRACKING TEST ==="
echo "Run this command and grep for '[BUFFER_TRACK]' to see buffer analysis:"
echo "grep '[BUFFER_TRACK]' <output_file>"
echo ""
echo "Starting FFmpeg with comprehensive buffer tracking..."
echo "Press Ctrl+C to stop"
echo ""

# Run FFmpeg with buffer tracking and save output to file
timeout 30s ./ffmpeg \
  -fflags nobuffer -flags low_delay \
  -analyzeduration 0 -probesize 32 -max_delay 0 \
  -flush_packets 1 \
  -loglevel info \
  -msw.enable -msw.sources "s0=local;s1=local;s2=local" \
  -msw.auto.enable -msw.auto.recovery_delay 2000 \
  -i "udp://127.0.0.1:12350?fifo_size=1&overrun_nonfatal=1&timeout=1000000&buffer_size=65536" \
  -i "udp://127.0.0.1:12351?fifo_size=1&overrun_nonfatal=1&timeout=1000000&buffer_size=65536" \
  -i "udp://127.0.0.1:12352?fifo_size=1&overrun_nonfatal=1&timeout=1000000&buffer_size=65536" \
  -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0:tube=2,fps=30[out]" \
  -map "[out]" -c:v libx264 -r 30 -preset ultrafast -g 30 -keyint_min 1 -sc_threshold 0 \
  -pix_fmt yuv420p -f mpegts - > buffer_tracking_output.log 2>&1

echo ""
echo "=== BUFFER ANALYSIS ==="
echo "Analyzing buffer tracking data..."

# Extract key buffer tracking information
echo ""
echo "=== STARTUP PHASE TRACKING ==="
grep "\[BUFFER_TRACK\].*Startup" buffer_tracking_output.log | head -10

echo ""
echo "=== FILTER BUFFER TRACKING ==="
grep "\[BUFFER_TRACK\].*MSwitch Filter" buffer_tracking_output.log | head -10

echo ""
echo "=== MAIN LOOP TRACKING ==="
grep "\[BUFFER_TRACK\].*FFmpeg Main" buffer_tracking_output.log | head -10

echo ""
echo "=== UDP BUFFER OVERRUNS ==="
grep "Circular buffer overrun" buffer_tracking_output.log | wc -l | xargs echo "Overruns:"

echo ""
echo "=== FRAME TIMING ANALYSIS ==="
grep "frame=" buffer_tracking_output.log | head -5
grep "frame=" buffer_tracking_output.log | tail -5

echo ""
echo "=== COMPLETE BUFFER TRACKING LOG ==="
echo "Full log saved to: buffer_tracking_output.log"
echo "Use: grep '[BUFFER_TRACK]' buffer_tracking_output.log"
echo ""

# Cleanup
cleanup() {
    echo "Cleaning up..."
    kill $RED_PID $GREEN_PID $BLUE_PID 2>/dev/null
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT
