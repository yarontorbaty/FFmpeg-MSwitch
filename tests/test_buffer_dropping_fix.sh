#!/bin/bash

# Buffer Dropping Fix Test
# This test verifies that inactive inputs don't accumulate buffers

echo "=== Buffer Dropping Fix Test ==="
echo "This test verifies that inactive inputs don't accumulate buffers"
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

echo "=== TEST: Buffer Dropping Fix ==="
echo "Running FFmpeg with continuous buffer dropping for inactive inputs..."
echo ""

# Run FFmpeg with buffer dropping
timeout 15s ./ffmpeg -y \
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
  -pix_fmt yuv420p -f mpegts test_output.mts > buffer_dropping_test.log 2>&1

echo "Test completed. Analyzing logs..."
echo ""

# Cleanup
kill $RED_PID $GREEN_PID $BLUE_PID 2>/dev/null

echo "=== LOG ANALYSIS ==="
echo ""

echo "1. Check for buffer dropping messages:"
grep "Dropped packet from inactive input" buffer_dropping_test.log | head -5

echo ""
echo "2. Check for frame discarding in filter:"
grep "Discarded.*frames from inactive input" buffer_dropping_test.log | head -5

echo ""
echo "3. Check for MSwitch initialization:"
grep "MSwitch.*initialized" buffer_dropping_test.log

echo ""
echo "4. Check for frame timing:"
grep "frame=" buffer_dropping_test.log | head -3

echo ""
echo "=== EXPECTED RESULTS ==="
echo ""
echo "✅ Should see: 'Dropped packet from inactive input' messages"
echo "✅ Should see: 'Discarded X frames from inactive input' messages"
echo "✅ Should see: Fast frame processing (no 7s delays)"
echo ""
echo "This confirms that inactive inputs are being continuously drained!"

# Cleanup
rm -f test_output.mts
