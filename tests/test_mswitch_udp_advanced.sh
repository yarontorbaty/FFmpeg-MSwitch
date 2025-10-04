#!/bin/bash

# Advanced MSwitch Test with Simultaneous UDP Ingestion
# Uses FFmpeg's native simultaneous input handling

echo "=== Advanced MSwitch UDP Test ==="
echo "Using FFmpeg's simultaneous input processing..."

# Start all UDP sources in parallel
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

# Wait for sources to start
sleep 3

echo "Starting MSwitch with advanced UDP optimizations..."
echo "Optimizations applied:"
echo "- Simultaneous input processing"
echo "- Minimal buffering and latency"
echo "- UDP-specific optimizations"
echo "- Fast startup and switching"

# Advanced optimized command
./ffmpeg \
  -fflags nobuffer -flags low_delay \
  -analyzeduration 0 -probesize 32 -max_delay 0 \
  -flush_packets 1 \
  -msw.enable -msw.sources "s0=local;s1=local;s2=local" \
  -msw.auto.enable -msw.auto.recovery_delay 2000 \
  -msw.webhook.enable -msw.webhook.port 8099 \
  -thread_queue_size 1024 \
  -i "udp://127.0.0.1:12350?fifo_size=10000&overrun_nonfatal=1&timeout=1000000&buffer_size=65536" \
  -thread_queue_size 1024 \
  -i "udp://127.0.0.1:12351?fifo_size=10000&overrun_nonfatal=1&timeout=1000000&buffer_size=65536" \
  -thread_queue_size 1024 \
  -i "udp://127.0.0.1:12352?fifo_size=10000&overrun_nonfatal=1&timeout=1000000&buffer_size=65536" \
  -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0,fps=30[out]" \
  -map "[out]" -c:v libx264 -r 30 -preset ultrafast -g 60 -keyint_min 1 -sc_threshold 0 \
  -pix_fmt yuv420p -f mpegts - | ffplay -fflags nobuffer -flags low_delay -i - -loglevel warning
# Cleanup
cleanup() {
    echo "Cleaning up..."
    kill $RED_PID $GREEN_PID $BLUE_PID 2>/dev/null
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT
