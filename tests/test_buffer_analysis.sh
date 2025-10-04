#!/bin/bash

# Buffer Analysis Test
# This test analyzes buffer differences between sources to understand the freeze issue

echo "=== Buffer Analysis Test ==="
echo "Analyzing buffer differences between sources to understand 0→1 freeze"
echo ""

# Start UDP sources
echo "Starting UDP sources..."
ffmpeg -f lavfi -re -i "color=red:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='RED %{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 30 -keyint_min 1 -sc_threshold 0 \
  -f mpegts udp://127.0.0.1:12350 > /dev/null 2>&1 &
RED_PID=$!

ffmpeg -f lavfi -re -i "color=green:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='GREEN %{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 30 -keyint_min 1 -sc_threshold 0 \
  -f mpegts udp://127.0.0.1:12351 > /dev/null 2>&1 &
GREEN_PID=$!

ffmpeg -f lavfi -re -i "color=blue:size=1280x720:rate=30" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='BLUE %{localtime}.%{eif\:1M*t-1K*trunc(t*1K)\:d}':x=40:y=60:fontsize=64:fontcolor=white:box=1:boxcolor=0x00000088" \
  -c:v libx264 -r 30 -preset ultrafast -tune zerolatency -g 30 -keyint_min 1 -sc_threshold 0 \
  -f mpegts udp://127.0.0.1:12352 > /dev/null 2>&1 &
BLUE_PID=$!

sleep 3

echo "=== TEST: Buffer Analysis ==="
echo "Running FFmpeg with buffer analysis..."
echo ""

# Run FFmpeg with buffer analysis
timeout 20s ./ffmpeg -y \
  -fflags nobuffer -flags low_delay \
  -analyzeduration 0 -probesize 32 -max_delay 0 \
  -flush_packets 1 \
  -loglevel info \
  -msw.enable -msw.sources "s0=local;s1=local;s2=local" \
  -i "udp://127.0.0.1:12350?fifo_size=10240&overrun_nonfatal=1&timeout=1000000&buffer_size=65536" \
  -i "udp://127.0.0.1:12351?fifo_size=10240&overrun_nonfatal=1&timeout=1000000&buffer_size=65536" \
  -i "udp://127.0.0.1:12352?fifo_size=10240&overrun_nonfatal=1&timeout=1000000&buffer_size=65536" \
  -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0:tube=2,fps=30[out]" \
  -map "[out]" -c:v libx264 -r 30 -preset ultrafast -g 30 -keyint_min 1 -sc_threshold 0 \
  -pix_fmt yuv420p -f mpegts test_output.mts > buffer_analysis_test.log 2>&1

echo "Test completed. Analyzing buffer patterns..."
echo ""

# Cleanup
kill $RED_PID $GREEN_PID $BLUE_PID 2>/dev/null

echo "=== BUFFER ANALYSIS ==="
echo ""

echo "1. Buffer sizes during normal operation:"
grep "Input.*buffer:" buffer_analysis_test.log | head -10

echo ""
echo "2. Switch events and buffer clearing:"
grep "Switched from input" buffer_analysis_test.log

echo ""
echo "3. Buffer sizes before clearing:"
grep "has.*queued frames before clearing" buffer_analysis_test.log

echo ""
echo "4. Frames cleared during switches:"
grep "Cleared.*buffered frames from inactive input" buffer_analysis_test.log

echo ""
echo "5. Frame processing timing:"
grep "frame=" buffer_analysis_test.log | head -5

echo ""
echo "=== ANALYSIS SUMMARY ==="
echo ""
echo "Look for patterns in buffer sizes:"
echo "- Input 0 (initial active): Should have large buffers"
echo "- Inputs 1,2 (inactive): Should have small/no buffers"
echo "- When switching 0→1: Input 0 should have many frames to clear"
echo "- When switching 1→0: Input 1 should have few frames to clear"
echo ""
echo "This explains why 0→1 has freeze (large buffer to clear) but 1→0 doesn't!"

# Cleanup
rm -f test_output.mts
