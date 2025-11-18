#!/bin/bash
# Extended Auto-Revert Test - keeps sources running throughout
# Tests auto-revert when Source 0 recovers while Source 1 is still healthy

set -e

echo "========================================="
echo "Auto-Revert Extended Test"
echo "========================================="
echo ""

# Configuration
OUTPUT_FILE="test_auto_revert_extended.mp4"
SOURCE_DURATION=120  # Sources run for 2 minutes
TEST_DURATION=60     # Receiver runs for 1 minute

# Cleanup
cleanup() {
    echo ""
    echo "Cleaning up..."
    pkill -f "lavfi.*testsrc" || true
    pkill -f "mswitchdirect" || true
    sleep 1
}

trap cleanup EXIT
cleanup

echo "Starting long-running sources (2 minutes each)"
echo "========================================="
echo ""

# Source 0 (RED - Priority 1)
echo "Starting Source 0 (RED)..."
./ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=$SOURCE_DURATION:size=640x480:rate=30,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 0 - PRIORITY 1':fontsize=36:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=black@0.5,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='%{pts\:hms}':fontsize=24:fontcolor=yellow:x=(w-text_w)/2:y=(h-50):box=1:boxcolor=black@0.5,format=yuv420p,drawbox=color=red@0.4:t=fill" \
    -f lavfi -i "sine=frequency=440:duration=$SOURCE_DURATION" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 1000k -g 30 \
    -c:a aac -b:a 64k \
    -f mpegts "srt://127.0.0.1:9100?mode=caller" \
    > source0_ext.log 2>&1 &
SOURCE0_PID=$!

# Source 1 (GREEN - Priority 2)
echo "Starting Source 1 (GREEN)..."
./ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=$SOURCE_DURATION:size=640x480:rate=30,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 1 - PRIORITY 2':fontsize=36:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=black@0.5,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='%{pts\:hms}':fontsize=24:fontcolor=yellow:x=(w-text_w)/2:y=(h-50):box=1:boxcolor=black@0.5,format=yuv420p,drawbox=color=green@0.4:t=fill" \
    -f lavfi -i "sine=frequency=880:duration=$SOURCE_DURATION" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 1000k -g 30 \
    -c:a aac -b:a 64k \
    -f mpegts "srt://127.0.0.1:9101?mode=caller" \
    > source1_ext.log 2>&1 &
SOURCE1_PID=$!

echo "Source PIDs: 0=$SOURCE0_PID, 1=$SOURCE1_PID"
sleep 3

echo ""
echo "Starting receiver with auto-revert"
echo "========================================="
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
    > receiver_ext.log 2>&1 &
RECEIVER_PID=$!

echo "Receiver PID: $RECEIVER_PID"
echo ""

echo "Test Timeline:"
echo "========================================="
echo " 0s: Both sources active, Source 0 should be selected"
echo "10s: Kill Source 0 → failover to Source 1"
echo "15s: Restart Source 0 → should auto-revert after 8s"
echo "23s: Auto-revert should occur (Source 0 active again)"
echo "60s: Test ends"
echo ""

sleep 2

echo "[T+0s] Monitoring initial state..."
sleep 8

echo "[T+10s] Killing Source 0..." | tee -a test_timeline.log
echo "$(date +%T): Killing Source 0" >> test_timeline.log
kill $SOURCE0_PID 2>/dev/null || true
echo "✓ Source 0 killed"

sleep 5

echo ""
echo "[T+15s] Restarting Source 0..." | tee -a test_timeline.log
echo "$(date +%T): Restarting Source 0" >> test_timeline.log
./ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=$SOURCE_DURATION:size=640x480:rate=30,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 0 - RECOVERED':fontsize=36:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=black@0.5,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='%{pts\:hms}':fontsize=24:fontcolor=yellow:x=(w-text_w)/2:y=(h-50):box=1:boxcolor=black@0.5,format=yuv420p,drawbox=color=red@0.4:t=fill" \
    -f lavfi -i "sine=frequency=440:duration=$SOURCE_DURATION" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 1000k -g 30 \
    -c:a aac -b:a 64k \
    -f mpegts "srt://127.0.0.1:9100?mode=caller" \
    >> source0_ext.log 2>&1 &
SOURCE0_PID=$!
echo "✓ Source 0 restarted (PID: $SOURCE0_PID)"

echo ""
echo "[T+15-23s] Waiting for auto-revert (should occur at ~23s)..."
for i in {1..10}; do
    sleep 1
    echo -n "."
done
echo ""

echo ""
echo "[T+25s] Checking if auto-revert occurred..."
if grep -q "AUTO-REVERT" receiver_ext.log; then
    echo "✅ AUTO-REVERT detected!"
    grep "AUTO-REVERT" receiver_ext.log
else
    echo "⚠️  No AUTO-REVERT yet, continuing to monitor..."
fi

echo ""
echo "[T+25-60s] Continuing test, both sources should remain healthy..."
echo "Waiting for receiver to complete..."

# Wait for receiver
wait $RECEIVER_PID 2>/dev/null || true

echo ""
echo "========================================="
echo "Test Analysis"
echo "========================================="
echo ""

echo "1. Failover Events:"
grep -E "AUTO-FAILOVER|AUTO-REVERT" receiver_ext.log || echo "   None found"

echo ""
echo "2. Health Events (first 15):"
grep -E "unhealthy|recovered|ready for.*revert" receiver_ext.log | head -15 || echo "   None found"

echo ""
echo "3. Source 0 recovery detection:"
grep -i "source 0.*recovered" receiver_ext.log || echo "   Not logged"

echo ""
echo "4. Revert readiness checks:"
grep -i "ready for auto-revert\|revert blocked\|not stable" receiver_ext.log || echo "   Not logged"

echo ""
if [ -f "$OUTPUT_FILE" ]; then
    echo "✅ Output file: $OUTPUT_FILE"
    ls -lh "$OUTPUT_FILE"
    echo ""
    echo "Play with: ffplay $OUTPUT_FILE"
    echo ""
    echo "Expected visual pattern:"
    echo "   0-10s:  RED (Source 0)"
    echo "  10-23s:  GREEN (Source 1 after failover)"
    echo "  23-60s:  RED (Source 0 after auto-revert)"
fi

echo ""
echo "========================================="
if grep -q "AUTO-REVERT" receiver_ext.log; then
    echo "🎉 SUCCESS: Auto-revert working!"
elif grep -q "AUTO-FAILOVER.*1 to 0" receiver_ext.log; then
    echo "⚠️  Switched back to Source 0, but via FAILOVER (not REVERT)"
    echo "    This means Source 1 died before auto-revert could trigger"
else
    echo "❌ Auto-revert did not occur"
fi
echo "========================================="
echo ""

