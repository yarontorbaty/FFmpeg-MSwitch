#!/bin/bash

# Test freeze-frame failover with mswitchdirect demuxer
# This test demonstrates that when a source fails, the system enters freeze-frame mode
# (repeating the last good frame) while the health monitor finds a healthy source

echo "=== MSwitch Direct: Freeze-Frame Failover Test ==="
echo ""
echo "This test demonstrates:"
echo "1. Source 0 (red) starts as active"
echo "2. When you stop source 0, system enters FREEZE-FRAME mode (last red frame repeats)"
echo "3. Health monitor finds source 1 (green) in background"
echo "4. System switches to source 1 on next I-frame"
echo "5. NO BLACK INTERIM FILE - seamless freeze-to-recovery"
echo ""

# Kill any existing FFmpeg processes on port 8099
echo "Cleaning up any existing processes..."
lsof -ti:8099 | xargs kill -9 2>/dev/null || true
sleep 1

# Check if UDP sources are running
echo ""
echo "Checking UDP sources..."
if ! lsof -i:12350 > /dev/null 2>&1; then
    echo "❌ ERROR: UDP source on port 12350 is not running!"
    echo "Please start it in a separate terminal:"
    echo "  ffmpeg -re -f lavfi -i testsrc=size=1280x720:rate=30,format=yuv420p -f lavfi -i color=red:size=1280x720:rate=30 -map 1:v -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -keyint_min 1 -sc_threshold 0 -b:v 500k -pix_fmt yuv420p -f mpegts 'udp://127.0.0.1:12350?pkt_size=1316'"
    exit 1
fi

if ! lsof -i:12351 > /dev/null 2>&1; then
    echo "❌ ERROR: UDP source on port 12351 is not running!"
    echo "Please start it in a separate terminal:"
    echo "  ffmpeg -re -f lavfi -i testsrc=size=1280x720:rate=30,format=yuv420p -f lavfi -i color=green:size=1280x720:rate=30 -map 1:v -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -keyint_min 1 -sc_threshold 0 -b:v 500k -pix_fmt yuv420p -f mpegts 'udp://127.0.0.1:12351?pkt_size=1316'"
    exit 1
fi

if ! lsof -i:12352 > /dev/null 2>&1; then
    echo "❌ ERROR: UDP source on port 12352 is not running!"
    echo "Please start it in a separate terminal:"
    echo "  ffmpeg -re -f lavfi -i testsrc=size=1280x720:rate=30,format=yuv420p -f lavfi -i color=blue:size=1280x720:rate=30 -map 1:v -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -keyint_min 1 -sc_threshold 0 -b:v 500k -pix_fmt yuv420p -f mpegts 'udp://127.0.0.1:12352?pkt_size=1316'"
    exit 1
fi

echo "✅ All UDP sources are running"
echo ""

# Start FFmpeg with freeze-frame failover
echo "Starting FFmpeg with freeze-frame failover..."
echo "Command:"
echo "./ffmpeg -y -v info \\"
echo "  -f mswitchdirect \\"
echo "  -msw_sources 'udp://127.0.0.1:12350,udp://127.0.0.1:12351,udp://127.0.0.1:12352' \\"
echo "  -msw_port 8099 \\"
echo "  -msw_auto_failover 1 \\"
echo "  -msw_health_interval 50 \\"
echo "  -msw_source_timeout 50 \\"
echo "  -msw_grace_period 0 \\"
echo "  -i dummy \\"
echo "  -c:v libx264 -r 30 -preset ultrafast -g 60 -keyint_min 1 -sc_threshold 0 -pix_fmt yuv420p \\"
echo "  -f mpegts /dev/null"
echo ""
echo "Running in background..."
echo ""

./ffmpeg -y -v info \
  -f mswitchdirect \
  -msw_sources "udp://127.0.0.1:12350,udp://127.0.0.1:12351,udp://127.0.0.1:12352" \
  -msw_port 8099 \
  -msw_auto_failover 1 \
  -msw_health_interval 50 \
  -msw_source_timeout 50 \
  -msw_grace_period 0 \
  -i dummy \
  -c:v libx264 -r 30 -preset ultrafast -g 60 -keyint_min 1 -sc_threshold 0 -pix_fmt yuv420p \
  -f mpegts /dev/null > freeze_frame_test.log 2>&1 &

FFMPEG_PID=$!
echo "FFmpeg PID: $FFMPEG_PID"
echo ""

# Wait for FFmpeg to start
echo "Waiting for FFmpeg to initialize..."
sleep 3

echo ""
echo "=== INSTRUCTIONS ==="
echo ""
echo "1. FFmpeg is now running with source 0 (red) active"
echo "2. To test freeze-frame failover:"
echo "   - Find the terminal running UDP source on port 12350 (red)"
echo "   - Press Ctrl+C to stop it"
echo "3. Watch the logs for:"
echo "   - '❄️  Source 0 failed, entering FREEZE-FRAME mode'"
echo "   - '❄️  Freeze-frame: repeating last packet'"
echo "   - 'Source 0 (ACTIVE) unhealthy'"
echo "   - '🔄 AUTO-FAILOVER pending: Source 0 → 1'"
echo "   - '✅ SWITCHED: Source 0 → 1'"
echo "4. The output will show:"
echo "   - Frozen red frame (last good frame from source 0)"
echo "   - Then smooth transition to green (source 1)"
echo "   - NO BLACK SCREEN!"
echo ""
echo "Press Ctrl+C here when done testing"
echo ""

# Tail the log file
tail -f freeze_frame_test.log

# Cleanup on exit
trap "kill $FFMPEG_PID 2>/dev/null; exit" INT TERM EXIT
