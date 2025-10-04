#!/bin/bash

# Threading Diagnosis Test
# This test diagnoses whether inputs are being processed in parallel threads

echo "=== Threading Diagnosis Test ==="
echo "Checking if inputs are processed in parallel with separate buffers"
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

echo "=== TEST: Threading Diagnosis ==="
echo "Running FFmpeg with threading diagnosis..."
echo ""

# Run FFmpeg with threading diagnosis
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
  -pix_fmt yuv420p -f mpegts test_output.mts > threading_diagnosis.log 2>&1

echo "Test completed. Analyzing threading and buffers..."
echo ""

# Cleanup
kill $RED_PID $GREEN_PID $BLUE_PID 2>/dev/null

echo "=== THREADING ANALYSIS ==="
echo ""

echo "1. Check for buffer status messages:"
grep "\[MSwitch\] Buffer status" threading_diagnosis.log | head -10

echo ""
echo "2. Check for input thread initialization:"
grep -i "input.*thread\|demux.*thread" threading_diagnosis.log

echo ""
echo "3. Check for filter input status:"
grep "Input.*frames queued" threading_diagnosis.log | head -10

echo ""
echo "4. Check for frame forwarding:"
grep "FF_FILTER_FORWARD" threading_diagnosis.log

echo ""
echo "5. Check for switching:"
grep "Switched from input" threading_diagnosis.log

echo ""
echo "=== DIAGNOSIS SUMMARY ==="
echo ""
echo "Expected findings:"
echo "- ✅ Buffer status should show frames queued for ALL inputs (not just active)"
echo "- ✅ Input 0 (active): Should have frames queued"
echo "- ✅ Inputs 1,2 (inactive): Should ALSO have frames queued (not 0)"
echo "- ❌ If inactive inputs show 0 frames: Threading is NOT working properly"
echo ""
echo "If inactive inputs have 0 frames, the issue is that FFmpeg is not"
echo "actually ingesting them in parallel despite having input threads."

# Cleanup
rm -f test_output.mts
