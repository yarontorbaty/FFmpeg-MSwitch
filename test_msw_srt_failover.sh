#!/bin/bash

# Test script to verify the SRT auto-failover fix
# This reproduces the scenario from Issue #5

set -e

echo "🧪 Testing MSwitch Direct SRT Auto-Failover Fix"
echo "================================================"
echo ""
echo "This test simulates:"
echo "  • Two SRT sources (Source 0 on port 9000, Source 1 on port 9001)"
echo "  • Auto-failover enabled with 5-second health timeout"
echo "  • Manual disconnect of active source to trigger auto-failover"
echo ""
echo "Expected behavior:"
echo "  ✅ Auto-failover switches to backup source"
echo "  ✅ Backup source continues streaming (no disconnect)"
echo "  ✅ No 'Manual switch grace period' messages in logs"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "🧹 Cleaning up..."
    pkill -f "ffmpeg.*srt://127.0.0.1:900" 2>/dev/null || true
    sleep 2
}

trap cleanup EXIT

# Test configuration
OUTPUT_FILE="test_msw_srt_failover_output.ts"
LOG_FILE="test_msw_srt_failover.log"
SOURCE0_PORT=9000
SOURCE1_PORT=9001
HEALTH_TIMEOUT=5000  # 5 seconds (same as in the bug report)

echo "📝 Test configuration:"
echo "  • Source 0: srt://127.0.0.1:${SOURCE0_PORT}"
echo "  • Source 1: srt://127.0.0.1:${SOURCE1_PORT}"
echo "  • Health timeout: ${HEALTH_TIMEOUT}ms"
echo "  • Output: ${OUTPUT_FILE}"
echo "  • Logs: ${LOG_FILE}"
echo ""

# Remove old files
rm -f "${OUTPUT_FILE}" "${LOG_FILE}"

# Start Source 0 (will be primary)
echo "🎬 Starting Source 0 (Primary)..."
./ffmpeg -hide_banner -loglevel info \
    -f lavfi -i "testsrc=duration=120:size=1280x720:rate=30,format=yuv420p" \
    -f lavfi -i "sine=frequency=440:duration=120" \
    -vf "drawtext=text='SOURCE 0':fontsize=60:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2:box=1:boxcolor=blue@0.8:boxborderw=10" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 3M \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:${SOURCE0_PORT}?mode=listener&pkt_size=1316&latency=2000" \
    >/dev/null 2>&1 &
SOURCE0_PID=$!

sleep 5

# Start Source 1 (backup)
echo "🎬 Starting Source 1 (Backup)..."
./ffmpeg -hide_banner -loglevel info \
    -f lavfi -i "testsrc=duration=120:size=1280x720:rate=30,format=yuv420p" \
    -f lavfi -i "sine=frequency=880:duration=120" \
    -vf "drawtext=text='SOURCE 1':fontsize=60:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2:box=1:boxcolor=green@0.8:boxborderw=10" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 3M \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:${SOURCE1_PORT}?mode=listener&pkt_size=1316&latency=2000" \
    >/dev/null 2>&1 &
SOURCE1_PID=$!

sleep 5

# Start receiver with mswitchdirect
echo "📡 Starting MSwitch Direct receiver..."
echo "   (monitoring both sources, auto-failover enabled)"
./ffmpeg -hide_banner -loglevel debug \
    -f mswitchdirect \
    -msw_sources "srt://127.0.0.1:${SOURCE0_PORT}?mode=caller,srt://127.0.0.1:${SOURCE1_PORT}?mode=caller" \
    -msw_source_timeout "${HEALTH_TIMEOUT}" \
    -msw_auto_failover 1 \
    -i dummy \
    -c copy \
    -f mpegts "${OUTPUT_FILE}" \
    > "${LOG_FILE}" 2>&1 &
RECEIVER_PID=$!

echo "   PID: ${RECEIVER_PID}"
echo ""

# Wait for startup
echo "⏳ Waiting 10 seconds for streams to stabilize..."
sleep 10

# Check initial state
echo ""
echo "📊 Initial state (should be on Source 0):"
tail -n 5 "${LOG_FILE}" | grep -i "source\|switch\|active" || echo "   (no relevant logs yet)"
echo ""

# Trigger failover by killing Source 0
echo "💥 Simulating Source 0 failure (killing sender)..."
kill $SOURCE0_PID 2>/dev/null || true
echo "   Source 0 stopped"
echo ""

# Wait for health monitor to detect failure
WAIT_TIME=$((HEALTH_TIMEOUT / 1000 + 3))
echo "⏳ Waiting ${WAIT_TIME} seconds for health monitor to detect failure and trigger auto-failover..."
sleep $WAIT_TIME

# Check logs for auto-failover
echo ""
echo "🔍 Checking for auto-failover..."
if grep -q "AUTO-FAILOVER.*Switched from source 0 to 1" "${LOG_FILE}"; then
    echo "   ✅ Auto-failover detected in logs"
else
    echo "   ❌ No auto-failover found in logs!"
fi
echo ""

# Check for the bug: Manual switch grace period during auto-failover
echo "🐛 Checking for BUG (manual switch grace period during auto-failover)..."
if grep -q "Manual switch grace period" "${LOG_FILE}"; then
    echo "   ❌ BUG DETECTED: Found 'Manual switch grace period' messages"
    echo "   (This should NOT appear during auto-failover)"
    echo ""
    echo "   Example messages:"
    grep "Manual switch grace period" "${LOG_FILE}" | head -n 3 | sed 's/^/      /'
else
    echo "   ✅ NO BUG: No 'Manual switch grace period' messages found"
fi
echo ""

# Wait a few more seconds to see if Source 1 stays healthy
echo "⏳ Waiting 10 seconds to verify Source 1 remains stable..."
sleep 10

# Check if Source 1 is still active
echo ""
echo "🔍 Final check: Is Source 1 still streaming?"
if grep -q "AUTO-FAILOVER.*Switched from source 1 to 0" "${LOG_FILE}"; then
    echo "   ❌ FAIL: Unexpected fail-back to Source 0 detected!"
    echo "   (Source 1 should remain active since Source 0 is still dead)"
else
    echo "   ✅ PASS: Source 1 is still active (no fail-back)"
fi
echo ""

# Kill receiver
kill $RECEIVER_PID 2>/dev/null || true
kill $SOURCE1_PID 2>/dev/null || true
sleep 1

# Summary
echo ""
echo "═══════════════════════════════════════════════════"
echo "📊 Test Summary"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Key log events:"
grep -E "AUTO-FAILOVER|Manual switch grace period|Source.*unhealthy" "${LOG_FILE}" 2>/dev/null || echo "(no events found)"
echo ""
echo "Full logs saved to: ${LOG_FILE}"
echo "Output file: ${OUTPUT_FILE}"
echo ""

# Check for success criteria
HAS_AUTO_FAILOVER=$(grep "AUTO-FAILOVER.*Switched from source 0 to 1" "${LOG_FILE}" 2>/dev/null | wc -l | tr -d ' ')
HAS_GRACE_PERIOD=$(grep "Manual switch grace period" "${LOG_FILE}" 2>/dev/null | wc -l | tr -d ' ')
HAS_FAIL_BACK=$(grep "AUTO-FAILOVER.*Switched from source 1 to 0" "${LOG_FILE}" 2>/dev/null | wc -l | tr -d ' ')

echo "Test results:"
if [ "${HAS_AUTO_FAILOVER}" -gt 0 ]; then
    echo "  ✅ Auto-failover executed"
else
    echo "  ❌ Auto-failover did NOT execute"
fi

if [ "${HAS_GRACE_PERIOD}" -eq 0 ]; then
    echo "  ✅ No manual switch grace period (bug fixed)"
else
    echo "  ❌ Manual switch grace period detected (${HAS_GRACE_PERIOD} occurrences) - BUG STILL PRESENT"
fi

if [ "${HAS_FAIL_BACK}" -eq 0 ]; then
    echo "  ✅ No unexpected fail-back (Source 1 remained stable)"
else
    echo "  ❌ Unexpected fail-back detected (${HAS_FAIL_BACK} occurrences)"
fi
echo ""

# Overall verdict
if [ "${HAS_AUTO_FAILOVER}" -gt 0 ] && [ "${HAS_GRACE_PERIOD}" -eq 0 ] && [ "${HAS_FAIL_BACK}" -eq 0 ]; then
    echo "🎉 TEST PASSED: Fix verified successfully!"
    exit 0
else
    echo "❌ TEST FAILED: Issues detected"
    exit 1
fi

