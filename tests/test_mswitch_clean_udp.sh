#!/bin/bash

# Clean UDP Test - No Packet Corruption
# This test uses clean UDP sources to eliminate the 7s buffer issue

echo "=== Clean UDP Test (No Packet Corruption) ==="

# Start clean UDP sources with better encoding
echo "Starting clean UDP sources..."
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
echo "=== TEST 1: Direct UDP (Clean) ==="
echo "This should have minimal buffering (~1s)..."
echo "Press Ctrl+C to stop and move to next test"
echo ""

# Direct UDP test (clean)
timeout 10s ./ffmpeg \
  -fflags nobuffer -flags low_delay \
  -analyzeduration 0 -probesize 32 -max_delay 0 \
  -flush_packets 1 \
  -i "udp://127.0.0.1:12350?fifo_size=102400&overrun_nonfatal=1&timeout=1000000" \
  -c:v libx264 -r 30 -preset ultrafast -g 30 -keyint_min 1 -sc_threshold 0 \
  -pix_fmt yuv420p -f mpegts - | ffplay -fflags nobuffer -flags low_delay -i - -loglevel warning

echo ""
echo "=== TEST 2: MSwitch Filter (Clean) ==="
echo "This should now have minimal buffering (~1-2s)..."
echo "Press Ctrl+C to stop"
echo ""

# MSwitch filter test (clean)
timeout 20s ./ffmpeg \
  -fflags nobuffer -flags low_delay \
  -analyzeduration 0 -probesize 32 -max_delay 0 \
  -flush_packets 1 \
  -msw.enable -msw.sources "s0=local;s1=local;s2=local" \
  -msw.auto.enable -msw.auto.recovery_delay 2000 \
  -i "udp://127.0.0.1:12350?fifo_size=102400&overrun_nonfatal=1&timeout=1000000" \
  -i "udp://127.0.0.1:12351?fifo_size=102400&overrun_nonfatal=1&timeout=1000000" \
  -i "udp://127.0.0.1:12352?fifo_size=102400&overrun_nonfatal=1&timeout=1000000" \
  -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0,fps=30[out]" \
  -map "[out]" -c:v libx264 -r 30 -preset ultrafast -g 30 -keyint_min 1 -sc_threshold 0 \
  -pix_fmt yuv420p -f mpegts - | ffplay -fflags nobuffer -flags low_delay -i - -loglevel warning

# Cleanup
cleanup() {
    echo "Cleaning up..."
    kill $RED_PID $GREEN_PID $BLUE_PID 2>/dev/null
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT
