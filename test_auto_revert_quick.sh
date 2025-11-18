#!/bin/bash
# Quick Auto-Revert Test
# Tests priority-based failover and auto-revert functionality

set -e

echo "========================================="
echo "FFmpeg-MSwitch Auto-Revert Test"
echo "========================================="
echo ""

# Configuration
OUTPUT_FILE="test_auto_revert.mp4"
TEST_DURATION=40

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up processes..."
    pkill -f "lavfi.*testsrc" || true
    pkill -f "mswitchdirect" || true
    sleep 1
}

trap cleanup EXIT

# Initial cleanup
cleanup

echo "Step 1: Starting test sources"
echo "========================================="
echo ""

# Start Source 0 (RED - highest priority)
echo "Starting Source 0 (RED, Priority 1) on port 9100..."
./ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=$TEST_DURATION:size=640x480:rate=30,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 0':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=black@0.5,format=yuv420p,drawbox=color=red@0.4:t=fill" \
    -f lavfi -i "sine=frequency=440:duration=$TEST_DURATION" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 1000k -g 30 \
    -c:a aac -b:a 64k \
    -f mpegts "srt://127.0.0.1:9100?mode=caller" \
    > source0_test.log 2>&1 &
SOURCE0_PID=$!

# Start Source 1 (GREEN - lower priority)
echo "Starting Source 1 (GREEN, Priority 2) on port 9101..."
./ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=$TEST_DURATION:size=640x480:rate=30,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 1':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=black@0.5,format=yuv420p,drawbox=color=green@0.4:t=fill" \
    -f lavfi -i "sine=frequency=880:duration=$TEST_DURATION" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 1000k -g 30 \
    -c:a aac -b:a 64k \
    -f mpegts "srt://127.0.0.1:9101?mode=caller" \
    > source1_test.log 2>&1 &
SOURCE1_PID=$!

echo "Source 0 PID: $SOURCE0_PID"
echo "Source 1 PID: $SOURCE1_PID"
echo ""
echo "Waiting 3 seconds for sources to start..."
sleep 3

echo ""
echo "Step 2: Starting receiver with auto-revert"
echo "========================================="
echo ""

./ffmpeg -hide_banner -loglevel info \
    -f mswitchdirect \
    -msw_sources "srt://127.0.0.1:9100?mode=listener,srt://127.0.0.1:9101?mode=listener" \
    -msw_port 8099 \
    -msw_auto_failover 1 \
    -msw_auto_revert 1 \
    -msw_revert_delay 5000 \
    -msw_revert_stability_time 3000 \
    -msw_source_timeout 1000 \
    -i dummy \
    -c:v copy -c:a copy \
    -t $TEST_DURATION \
    -f mp4 -y "$OUTPUT_FILE" \
    > receiver_test.log 2>&1 &
RECEIVER_PID=$!

echo "Receiver PID: $RECEIVER_PID"
echo ""
echo "Configuration:"
echo "  - Auto-failover: enabled"
echo "  - Auto-revert: enabled"
echo "  - Revert delay: 5000ms"
echo "  - Stability time: 3000ms"
echo "  - Source timeout: 1000ms"
echo ""

sleep 2

echo ""
echo "Step 3: Test sequence"
echo "========================================="
echo ""

echo "[0-10s] Initial operation - Source 0 should be active (RED)"
echo "Waiting 10 seconds..."
sleep 10

echo ""
echo "[10s] Killing Source 0 to trigger failover..."
echo "Time: $(date +%T)"
kill $SOURCE0_PID 2>/dev/null || true
echo "✓ Source 0 killed"
echo ""

echo "[10-13s] Failover should occur within 1 second to Source 1 (GREEN)"
echo "Waiting 3 seconds..."
sleep 3

echo ""
echo "[13s] Restarting Source 0 to test auto-revert..."
echo "Time: $(date +%T)"
./ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=$TEST_DURATION:size=640x480:rate=30,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 0 RECOVERED':fontsize=40:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=black@0.5,format=yuv420p,drawbox=color=red@0.4:t=fill" \
    -f lavfi -i "sine=frequency=440:duration=$TEST_DURATION" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 1000k -g 30 \
    -c:a aac -b:a 64k \
    -f mpegts "srt://127.0.0.1:9100?mode=caller" \
    >> source0_test.log 2>&1 &
SOURCE0_PID=$!
echo "✓ Source 0 restarted (PID: $SOURCE0_PID)"
echo ""

echo "[13-21s] Waiting for auto-revert (3s stability + 5s delay)..."
echo "Auto-revert should occur around 21s"
sleep 8

echo ""
echo "[21s] Auto-revert should have occurred - back to Source 0 (RED)"
echo "Waiting for test to complete..."
sleep 7

echo ""
echo "Step 4: Analyzing results"
echo "========================================="
echo ""

# Wait for receiver to finish
wait $RECEIVER_PID 2>/dev/null || true

echo "✓ Test complete"
echo ""

# Analyze logs
echo "========================================="
echo "Results Analysis"
echo "========================================="
echo ""

echo "1. Checking for AUTO-FAILOVER event..."
if grep -q "AUTO-FAILOVER" receiver_test.log; then
    echo "   ✅ AUTO-FAILOVER detected:"
    grep "AUTO-FAILOVER" receiver_test.log | sed 's/^/      /'
else
    echo "   ❌ No AUTO-FAILOVER found"
fi

echo ""
echo "2. Checking for AUTO-REVERT event..."
if grep -q "AUTO-REVERT" receiver_test.log; then
    echo "   ✅ AUTO-REVERT detected:"
    grep "AUTO-REVERT" receiver_test.log | sed 's/^/      /'
else
    echo "   ❌ No AUTO-REVERT found"
fi

echo ""
echo "3. Health status changes:"
grep -E "(unhealthy|recovered)" receiver_test.log | head -10 | sed 's/^/   /'

echo ""
echo "4. Priority-based selection:"
grep -E "priority" receiver_test.log | sed 's/^/   /'

echo ""
echo "========================================="
echo "Output file: $OUTPUT_FILE"
if [ -f "$OUTPUT_FILE" ]; then
    FILE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
    DURATION=$(./ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUTPUT_FILE" 2>/dev/null | cut -d. -f1)
    echo "File size: $FILE_SIZE"
    echo "Duration: ${DURATION}s"
    echo ""
    echo "✅ Test completed successfully!"
    echo ""
    echo "Visual verification:"
    echo "  ffplay $OUTPUT_FILE"
    echo ""
    echo "Expected pattern:"
    echo "  0-10s:  RED screen (Source 0)"
    echo "  10-21s: GREEN screen (Source 1 after failover)"
    echo "  21s+:   RED screen (Source 0 after auto-revert)"
else
    echo "❌ Output file not created"
fi

echo ""
echo "Log files for detailed analysis:"
echo "  - receiver_test.log (main log)"
echo "  - source0_test.log"
echo "  - source1_test.log"
echo ""
echo "========================================="

# Summary
echo ""
if grep -q "AUTO-FAILOVER" receiver_test.log && grep -q "AUTO-REVERT" receiver_test.log; then
    echo "🎉 SUCCESS: Both failover and auto-revert working!"
elif grep -q "AUTO-FAILOVER" receiver_test.log; then
    echo "⚠️  PARTIAL: Failover works, but auto-revert did not occur"
else
    echo "❌ FAILED: Failover did not work as expected"
fi
echo ""

