#!/bin/bash

# Optimized MSwitch Test for UDP Sources with Simultaneous Ingestion
# This script addresses the sequential processing and buffering issues

echo "=== MSwitch UDP Optimized Test ==="
echo "Starting 3 UDP sources simultaneously..."

# Start all UDP sources in parallel (background processes)
echo "Starting RED source..."
ffmpeg -f lavfi -re -i "color=red:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='%{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 60 \
  -f mpegts udp://127.0.0.1:12350 &
RED_PID=$!

echo "Starting GREEN source..."
ffmpeg -f lavfi -re -i "color=green:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='%{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 60 \
  -f mpegts udp://127.0.0.1:12351 &
GREEN_PID=$!

echo "Starting BLUE source..."
ffmpeg -f lavfi -re -i "color=blue:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='%{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 60 \
  -f mpegts udp://127.0.0.1:12352 &
BLUE_PID=$!

# Wait a moment for sources to start
echo "Waiting 2 seconds for sources to initialize..."
sleep 2

echo "Starting MSwitch with optimized UDP settings..."
echo "Key optimizations:"
echo "- fflags nobuffer: Disable input buffering"
echo "- flags low_delay: Minimize delay"
echo "- analyzeduration 0: Don't analyze streams before starting"
echo "- probesize 32: Minimal probe size"
echo "- max_delay 0: No maximum delay"
echo "- avioflags direct: Direct I/O"
echo "- flush_packets: Flush packets immediately"

# Optimized MSwitch command with simultaneous UDP ingestion
./ffmpeg \
  -fflags nobuffer -flags low_delay \
  -analyzeduration 0 -probesize 32 -max_delay 0 \
  -flush_packets 1 \
  -msw.enable -msw.sources "s0=local;s1=local;s2=local" \
  -msw.auto.enable -msw.auto.recovery_delay 2000 \
  -msw.webhook.enable -msw.webhook.port 8099 \
  -i "udp://127.0.0.1:12350?fifo_size=102400&overrun_nonfatal=1&timeout=1000000" \
  -i "udp://127.0.0.1:12351?fifo_size=102400&overrun_nonfatal=1&timeout=1000000" \
  -i "udp://127.0.0.1:12352?fifo_size=102400&overrun_nonfatal=1&timeout=1000000" \
  -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0,fps=30[out]" \
  -map "[out]" -c:v libx264 -r 30 -preset ultrafast -g 60 -keyint_min 1 -sc_threshold 0 \
  -pix_fmt yuv420p -f mpegts - | ffplay -fflags nobuffer -flags low_delay -i - -loglevel warning
  
# Cleanup function
cleanup() {
    echo "Cleaning up sources..."
    kill $RED_PID $GREEN_PID $BLUE_PID 2>/dev/null
    exit 0
}

# Set up cleanup on script exit
trap cleanup SIGINT SIGTERM EXIT
