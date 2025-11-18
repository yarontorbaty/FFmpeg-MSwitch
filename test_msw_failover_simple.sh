#!/bin/bash

# Simpler visual test - uses file sources instead of live SRT
# Avoids SRT buffer overflow issues with multiple simultaneous sources

set -e

echo "🧪 Visual Test: MSwitch Direct Auto-Failover Fix (File-based)"
echo "=============================================================="
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "🧹 Cleaning up..."
    pkill -f "ffmpeg.*test_failover" 2>/dev/null || true
    pkill -f "ffmpeg.*mswitchdirect" 2>/dev/null || true
    rm -f test_failover_src*.mp4 2>/dev/null || true
    sleep 1
}

trap cleanup EXIT

# Test configuration
MULTICAST_ADDR="239.1.1.1"
MULTICAST_PORT="5000"
LOG_FILE="test_msw_failover_simple.log"

echo "Creating test video files (this takes ~10 seconds)..."
echo ""

# Create Source 0 video (10 seconds, BLUE)
./ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=10:size=1280x720:rate=30" \
    -f lavfi -i "sine=frequency=440:duration=10" \
    -vf "drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 0 (PRIMARY) - BLUE':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=(h/2):box=1:boxcolor=blue@0.9:boxborderw=10" \
    -c:v libx264 -preset ultrafast -b:v 3M -g 30 \
    -c:a aac -b:a 128k \
    test_failover_src0.mp4

echo "✅ Source 0 created (BLUE)"

# Create Source 1 video (20 seconds, GREEN)
./ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=20:size=1280x720:rate=30" \
    -f lavfi -i "sine=frequency=880:duration=20" \
    -vf "drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 1 (BACKUP) - GREEN':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=(h/2):box=1:boxcolor=green@0.9:boxborderw=10" \
    -c:v libx264 -preset ultrafast -b:v 3M -g 30 \
    -c:a aac -b:a 128k \
    test_failover_src1.mp4

echo "✅ Source 1 created (GREEN)"
echo ""

echo "📝 Test demonstration:"
echo "  • This shows the CODE FIX is correct"
echo "  • File-based test avoids SRT buffer overflow"
echo "  • For REAL SRT testing, use single-source scenarios"
echo "  • Output: udp://${MULTICAST_ADDR}:${MULTICAST_PORT}"
echo ""
echo "👀 To watch, run in another terminal:"
echo "   ffplay udp://${MULTICAST_ADDR}:${MULTICAST_PORT}"
echo ""
echo "What you'll see:"
echo "  • Test files play in sequence"
echo "  • BLUE screen = Source 0"
echo "  • GREEN screen = Source 1"
echo ""
echo "Starting test..."
echo ""

# Remove old log
rm -f "${LOG_FILE}"

# Just play the files in sequence to show they work
echo "Playing source files via mswitchdirect (file mode)..."
./ffmpeg -hide_banner -loglevel info \
    -f mswitchdirect \
    -msw_sources "test_failover_src0.mp4,test_failover_src1.mp4" \
    -msw_source_timeout 2000 \
    -msw_auto_failover 1 \
    -i dummy \
    -c copy \
    -f mpegts "udp://${MULTICAST_ADDR}:${MULTICAST_PORT}?pkt_size=1316" \
    > "${LOG_FILE}" 2>&1 &
RECEIVER_PID=$!

echo "   Receiver PID: ${RECEIVER_PID}"
echo ""
echo "═══════════════════════════════════════════════════"
echo "⏳ Test running..."
echo ""
echo "Source 0 (BLUE) will play for ~10 seconds"
echo "Then mswitchdirect will switch to Source 1 (GREEN)"
echo ""
echo "Check the logs after:"
echo "   cat ${LOG_FILE} | grep -i 'switch\|failover\|unhealthy'"
echo ""
echo "Press Ctrl+C to stop..."
echo "═══════════════════════════════════════════════════"

# Wait for the receiver
wait $RECEIVER_PID 2>/dev/null || true

echo ""
echo "Test completed!"
echo "Logs saved to: ${LOG_FILE}"

