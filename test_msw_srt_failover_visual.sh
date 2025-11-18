#!/bin/bash

# Visual test script for SRT auto-failover fix
# Outputs to multicast UDP so you can watch with ffplay

set -e

echo "🧪 Visual Test: MSwitch Direct SRT Auto-Failover Fix"
echo "======================================================"
echo ""
echo "This test will:"
echo "  • Start two SRT sources with burned-in timestamps"
echo "  • Output to multicast UDP (udp://239.1.1.1:5000)"
echo "  • You can watch with: ffplay udp://239.1.1.1:5000"
echo "  • Automatically fail Source 0 after 15 seconds"
echo "  • Watch for seamless switch to Source 1 (green)"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "🧹 Cleaning up..."
    pkill -f "ffmpeg.*srt://127.0.0.1:900" 2>/dev/null || true
    pkill -f "ffmpeg.*mswitchdirect" 2>/dev/null || true
    rm -f source0.log source1.log 2>/dev/null || true
    sleep 2
}

trap cleanup EXIT

# Test configuration
MULTICAST_ADDR="239.1.1.1"
MULTICAST_PORT="5000"
RECEIVER0_PORT=9000
RECEIVER1_PORT=9001
HEALTH_TIMEOUT=5000  # 5 seconds
LOG_FILE="test_msw_srt_failover_visual.log"

echo "📝 Test configuration:"
echo "  • Receiver 0 listening on: srt://0.0.0.0:${RECEIVER0_PORT} (will receive from Source 0 - BLUE)"
echo "  • Receiver 1 listening on: srt://0.0.0.0:${RECEIVER1_PORT} (will receive from Source 1 - GREEN)"
echo "  • Output: udp://${MULTICAST_ADDR}:${MULTICAST_PORT}"
echo "  • Health timeout: ${HEALTH_TIMEOUT}ms"
echo "  • Logs: ${LOG_FILE}"
echo ""
echo "👀 To watch, run in another terminal:"
echo "   ffplay -fflags nobuffer -flags low_delay -framedrop udp://${MULTICAST_ADDR}:${MULTICAST_PORT}"
echo ""
echo "Starting in 3 seconds..."
sleep 3

# Remove old files
rm -f "${LOG_FILE}"

# Start receiver with mswitchdirect FIRST (as listeners)
echo "📡 Starting MSwitch Direct receiver (will listen for SRT sources)..."
echo "   (monitoring both sources, auto-failover enabled)"
./ffmpeg -hide_banner -loglevel info \
    -f mswitchdirect \
    -msw_sources "srt://0.0.0.0:${RECEIVER0_PORT}?mode=listener,srt://0.0.0.0:${RECEIVER1_PORT}?mode=listener" \
    -msw_source_timeout "${HEALTH_TIMEOUT}" \
    -msw_auto_failover 1 \
    -i dummy \
    -c copy \
    -f mpegts "udp://${MULTICAST_ADDR}:${MULTICAST_PORT}?pkt_size=1316" \
    > "${LOG_FILE}" 2>&1 &
RECEIVER_PID=$!
echo "   PID: ${RECEIVER_PID}"
echo "   Waiting for SRT listeners to be ready..."

sleep 3

# Start Source 0 (will be primary, BLUE) - pushes to receiver
echo "🎬 Starting Source 0 (Primary, BLUE) - pushing to receiver..."
./ffmpeg -hide_banner -loglevel info \
    -f lavfi -i "testsrc=duration=120:size=1280x720:rate=30,format=yuv420p" \
    -f lavfi -i "sine=frequency=440:duration=120" \
    -vf "drawtext=text='SOURCE 0 (PRIMARY)':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=blue@0.9:boxborderw=10,\
         drawtext=text='Time\\: %{pts\\:hms}':fontsize=36:fontcolor=yellow:x=(w-text_w)/2:y=(h-100):box=1:boxcolor=black@0.7:boxborderw=5" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 3M -g 30 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:${RECEIVER0_PORT}?mode=caller&pkt_size=1316&latency=2000" \
    > source0.log 2>&1 &
SOURCE0_PID=$!
echo "   PID: ${SOURCE0_PID}"

sleep 3

# Start Source 1 (backup, GREEN) - pushes to receiver
echo "🎬 Starting Source 1 (Backup, GREEN) - pushing to receiver..."
./ffmpeg -hide_banner -loglevel info \
    -f lavfi -i "testsrc=duration=120:size=1280x720:rate=30,format=yuv420p" \
    -f lavfi -i "sine=frequency=880:duration=120" \
    -vf "drawtext=text='SOURCE 1 (BACKUP)':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=green@0.9:boxborderw=10,\
         drawtext=text='Time\\: %{pts\\:hms}':fontsize=36:fontcolor=yellow:x=(w-text_w)/2:y=(h-100):box=1:boxcolor=black@0.7:boxborderw=5" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 3M -g 30 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:${RECEIVER1_PORT}?mode=caller&pkt_size=1316&latency=2000" \
    > source1.log 2>&1 &
SOURCE1_PID=$!
echo "   PID: ${SOURCE1_PID}"

# Give instructions
echo "═══════════════════════════════════════════════════"
echo "🎥 NOW WATCHING:"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Open another terminal and run:"
echo ""
echo "  ffplay -fflags nobuffer -flags low_delay -framedrop udp://${MULTICAST_ADDR}:${MULTICAST_PORT}"
echo ""
echo "What to expect:"
echo "  0-15s:  You'll see SOURCE 0 (BLUE) with timestamp"
echo "  15s:    Source 0 will be killed"
echo "  ~20s:   Auto-failover to SOURCE 1 (GREEN)"
echo "  20s+:   SOURCE 1 continues with its timestamp"
echo ""
echo "Look for:"
echo "  ✅ Clean switch from BLUE → GREEN"
echo "  ✅ Timestamp continuity (should be smooth, no big jumps)"
echo "  ✅ GREEN source stays stable (no disconnect)"
echo ""
echo "═══════════════════════════════════════════════════"
echo ""

# Wait for startup
echo "⏳ Waiting 10 seconds for streams to stabilize..."
sleep 10

# Check initial state
echo ""
echo "📊 Initial state (should be on Source 0 - BLUE):"
tail -n 3 "${LOG_FILE}" | grep -i "source\|switch\|active" || echo "   (streaming...)"
echo ""

# Trigger failover by killing Source 0
echo "💥 Triggering failover in 5 seconds..."
sleep 5
echo "💥 KILLING Source 0 (BLUE) NOW..."
kill $SOURCE0_PID 2>/dev/null || true
echo "   Source 0 stopped"
echo ""

# Wait for health monitor to detect failure
WAIT_TIME=$((HEALTH_TIMEOUT / 1000 + 3))
echo "⏳ Waiting ${WAIT_TIME} seconds for auto-failover..."
echo "   (Watch your ffplay window - it should switch to GREEN)"
sleep $WAIT_TIME

# Check logs for auto-failover
echo ""
echo "🔍 Checking logs for auto-failover..."
if grep -q "AUTO-FAILOVER.*Switched from source 0 to 1" "${LOG_FILE}"; then
    echo "   ✅ Auto-failover detected!"
    echo ""
    echo "   Log excerpt:"
    grep "AUTO-FAILOVER" "${LOG_FILE}" | sed 's/^/      /'
else
    echo "   ❌ No auto-failover found in logs!"
fi
echo ""

# Check for the bug
echo "🐛 Checking for BUG (manual switch grace period during auto-failover)..."
if grep -q "Manual switch grace period" "${LOG_FILE}"; then
    echo "   ❌ BUG DETECTED: Found 'Manual switch grace period' messages"
    echo ""
    echo "   Example messages:"
    grep "Manual switch grace period" "${LOG_FILE}" | head -n 3 | sed 's/^/      /'
else
    echo "   ✅ NO BUG: No 'Manual switch grace period' messages found"
fi
echo ""

# Wait to see if Source 1 stays healthy
echo "⏳ Waiting 15 seconds to verify Source 1 (GREEN) remains stable..."
echo "   (Keep watching ffplay - should stay GREEN without interruption)"
sleep 15

# Check if Source 1 is still active
echo ""
echo "🔍 Final check: Is Source 1 still streaming?"
if grep -q "AUTO-FAILOVER.*Switched from source 1" "${LOG_FILE}"; then
    echo "   ❌ FAIL: Unexpected fail-back detected!"
    echo "   (Source 1 should remain active)"
else
    echo "   ✅ PASS: Source 1 is still active (no fail-back)"
fi
echo ""

echo "═══════════════════════════════════════════════════"
echo "📊 Test Complete"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Review:"
echo "  • Did you see a clean switch from BLUE to GREEN?"
echo "  • Was the timestamp transition smooth (no big jumps)?"
echo "  • Did GREEN source stay stable without disconnecting?"
echo ""
echo "Logs saved to: ${LOG_FILE}"
echo ""
echo "Test will continue running. Press Ctrl+C to stop..."
echo "(Cleanup will happen automatically)"
echo ""

# Wait indefinitely for user to Ctrl+C
wait

