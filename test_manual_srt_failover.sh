#!/bin/bash

# Manual SRT failover test with -re flag and proper logging
# Run this in one terminal, it will manage everything

set -e

echo "🧪 Manual SRT Failover Test"
echo "============================"
echo ""

# Cleanup
cleanup() {
    echo ""
    echo "🧹 Cleaning up..."
    pkill -f "ffmpeg.*srt://127.0.0.1:900" 2>/dev/null || true
    pkill -f "ffmpeg.*mswitchdirect" 2>/dev/null || true
    sleep 2
}

trap cleanup EXIT

# Clean any previous processes
cleanup

echo "Starting receiver..."
./ffmpeg -hide_banner -loglevel info \
  -f mswitchdirect \
  -msw_sources "srt://0.0.0.0:9000?mode=listener,srt://0.0.0.0:9001?mode=listener" \
  -msw_source_timeout 500 \
  -msw_auto_failover 1 \
  -i dummy \
  -c copy \
  -f mpegts "udp://239.1.1.1:5000?pkt_size=1316" \
  > receiver_auto.log 2>&1 &
RECEIVER_PID=$!
echo "   Receiver PID: $RECEIVER_PID"

sleep 3

echo "Starting Source 0 (BLUE - will be killed at 15s)..."
./ffmpeg -hide_banner -re \
  -f lavfi -i "testsrc=duration=120:size=1280x720:rate=30" \
  -f lavfi -i "sine=frequency=440:duration=120" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 0 (PRIMARY)':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=(h/2):box=1:boxcolor=blue@0.9:boxborderw=10" \
  -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2M -g 30 \
  -c:a aac -b:a 128k \
  -f mpegts "srt://127.0.0.1:9000?mode=caller&pkt_size=1316" \
  > source0_auto.log 2>&1 &
SOURCE0_PID=$!
echo "   Source 0 PID: $SOURCE0_PID"

sleep 2

echo "Starting Source 1 (GREEN - backup)..."
./ffmpeg -hide_banner -re \
  -f lavfi -i "testsrc=duration=120:size=1280x720:rate=30" \
  -f lavfi -i "sine=frequency=880:duration=120" \
  -vf "drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 1 (BACKUP)':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=(h/2):box=1:boxcolor=green@0.9:boxborderw=10" \
  -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2M -g 30 \
  -c:a aac -b:a 128k \
  -f mpegts "srt://127.0.0.1:9001?mode=caller&pkt_size=1316" \
  > source1_auto.log 2>&1 &
SOURCE1_PID=$!
echo "   Source 1 PID: $SOURCE1_PID"

echo ""
echo "═══════════════════════════════════════════════════"
echo "✅ All processes started!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Now run in another terminal:"
echo "  ffplay -fflags nobuffer -flags low_delay udp://239.1.1.1:5000"
echo ""
echo "You should see BLUE screen (Source 0)"
echo ""
echo "Waiting 15 seconds..."
sleep 15

echo ""
echo "💥 Killing Source 0 to trigger failover..."
kill $SOURCE0_PID 2>/dev/null || true
echo "   Source 0 killed"
echo ""
echo "Waiting for failover (5-10 seconds)..."
sleep 10

echo ""
echo "📊 Checking logs for failover..."
if grep -q "AUTO-FAILOVER.*Switched from source 0 to 1" receiver_auto.log; then
    echo "   ✅ AUTO-FAILOVER DETECTED!"
    grep "AUTO-FAILOVER\|unhealthy" receiver_auto.log
else
    echo "   ❌ No auto-failover found"
fi

echo ""
echo "🐛 Checking for bug (manual switch grace period)..."
if grep -q "Manual switch grace period" receiver_auto.log; then
    echo "   ❌ BUG DETECTED: Manual switch grace period during auto-failover"
else
    echo "   ✅ NO BUG: No manual switch grace period"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "Test will continue for 30 more seconds..."
echo "Check ffplay - should show GREEN screen (Source 1)"
echo ""
echo "Press Ctrl+C to stop early"
echo "═══════════════════════════════════════════════════"

sleep 30

echo ""
echo "Test complete! Logs:"
echo "  receiver_auto.log"
echo "  source0_auto.log"
echo "  source1_auto.log"

