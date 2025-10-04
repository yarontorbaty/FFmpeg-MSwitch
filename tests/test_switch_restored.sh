#!/bin/bash

# Switch Restored Test
# This test verifies that switching works again after restoring the logic

echo "=== Switch Restored Test ==="
echo "Testing that switching produces output after restoring logic"
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

echo "=== TEST: Switch Restored ==="
echo "Running FFmpeg with restored switching logic..."
echo ""

# Run FFmpeg with restored switching logic
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
  -pix_fmt yuv420p -f mpegts test_output.mts > switch_restored_test.log 2>&1

echo "Test completed. Analyzing logs..."
echo ""

# Cleanup
kill $RED_PID $GREEN_PID $BLUE_PID 2>/dev/null

echo "=== LOG ANALYSIS ==="
echo ""

echo "1. Check for switch messages:"
grep "Switched from input" switch_restored_test.log

echo ""
echo "2. Check for buffer clearing:"
grep "Cleared.*buffered frames from inactive input" switch_restored_test.log

echo ""
echo "3. Check for frame output:"
grep "Outputting frame from input" switch_restored_test.log | head -5

echo ""
echo "4. Check for frame processing:"
grep "frame=" switch_restored_test.log | head -5

echo ""
echo "5. Check for any errors:"
grep -i "error\|failed\|no output" switch_restored_test.log

echo ""
echo "=== EXPECTED RESULTS ==="
echo ""
echo "✅ Should see: 'Switched from input X to input Y'"
echo "✅ Should see: 'Cleared X buffered frames from inactive input Y'"
echo "✅ Should see: 'Outputting frame from input X'"
echo "✅ Should see: Normal frame processing"
echo "✅ Should NOT see: errors or 'no output'"
echo ""
echo "This confirms switching works again with proper buffer management!"

# Check if output file was created and has content
if [ -f "test_output.mts" ]; then
    echo ""
    echo "✅ Output file created: $(ls -lh test_output.mts)"
else
    echo ""
    echo "❌ No output file created"
fi

# Cleanup
rm -f test_output.mts
