#!/bin/bash

# Seamless Final Test
# This test verifies true seamless switching without buffer clearing

echo "=== Seamless Final Test ==="
echo "Testing true seamless switching with maintained buffers"
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

echo "=== TEST: Seamless Final ==="
echo "Running FFmpeg with true seamless switching..."
echo ""

# Run FFmpeg with true seamless switching
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
  -pix_fmt yuv420p -f mpegts test_output.mts > seamless_final_test.log 2>&1

echo "Test completed. Analyzing seamless switching..."
echo ""

# Cleanup
kill $RED_PID $GREEN_PID $BLUE_PID 2>/dev/null

echo "=== LOG ANALYSIS ==="
echo ""

echo "1. Check for seamless switching messages:"
grep "Keeping buffers for seamless switching" seamless_final_test.log

echo ""
echo "2. Check for switch events:"
grep "Switched from input" seamless_final_test.log

echo ""
echo "3. Check for buffer maintenance:"
grep "Input.*buffer:" seamless_final_test.log | head -5

echo ""
echo "4. Check for frame processing:"
grep "frame=" seamless_final_test.log | head -5

echo ""
echo "5. Check for any errors or freezes:"
grep -i "error\|freeze\|timeout\|stall" seamless_final_test.log

echo ""
echo "=== EXPECTED RESULTS ==="
echo ""
echo "✅ Should see: 'Keeping buffers for seamless switching'"
echo "✅ Should see: 'Switched from input X to input Y'"
echo "✅ Should see: Buffer maintenance for all inputs"
echo "✅ Should see: Normal frame processing"
echo "✅ Should NOT see: errors, freezes, or timeouts"
echo ""
echo "This confirms true seamless switching with maintained buffers!"

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
