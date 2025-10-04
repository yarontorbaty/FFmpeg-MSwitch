#!/bin/bash

# Debug test for mswitchdirect demuxer
# This will capture detailed logs to verify concurrent buffering and switching

echo "========================================="
echo "MSwitch Direct Demuxer - DEBUG TEST"
echo "========================================="

cd "$(dirname "$0")/.."

# Step 1: Check if UDP sources are running
echo ""
echo "=== Checking if UDP sources are running ==="
echo ""

check_port() {
    # Check if any process is sending to this UDP port
    lsof -nP -iTCP:$1 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN && return 0
    ps aux | grep -E "udp://127.0.0.1:$1" | grep -v grep | grep -q ffmpeg && return 0
    return 1
}

PORTS_READY=true
for port in 12350 12351 12352; do
    if check_port $port; then
        echo "✅ Port $port: READY"
    else
        echo "❌ Port $port: NOT READY"
        PORTS_READY=false
    fi
done

if [ "$PORTS_READY" = false ]; then
    echo ""
    echo "=== Please start UDP sources in 3 separate terminals ==="
    echo ""
    echo "Terminal 1 (RED):"
    echo "./ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i \"aevalsrc=0|0:c=stereo:s=48000\" -pix_fmt yuv420p -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -keyint_min 1 -sc_threshold 0 -b:v 1M -c:a aac -f mpegts \"udp://127.0.0.1:12350?pkt_size=1316\""
    echo ""
    echo "Terminal 2 (GREEN):"
    echo "./ffmpeg -re -f lavfi -i \"color=green:size=1280x720:rate=30\" -f lavfi -i \"sine=frequency=440:sample_rate=48000\" -pix_fmt yuv420p -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -keyint_min 1 -sc_threshold 0 -b:v 1M -c:a aac -f mpegts \"udp://127.0.0.1:12351?pkt_size=1316\""
    echo ""
    echo "Terminal 3 (BLUE):"
    echo "./ffmpeg -re -f lavfi -i \"color=blue:size=1280x720:rate=30\" -f lavfi -i \"sine=frequency=880:sample_rate=48000\" -pix_fmt yuv420p -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -keyint_min 1 -sc_threshold 0 -b:v 1M -c:a aac -f mpegts \"udp://127.0.0.1:12352?pkt_size=1316\""
    echo ""
    read -p "Press Enter once all 3 sources are running..."
fi

# Step 2: Skip cleanup - don't kill UDP sources
echo ""
echo "=== Skipping cleanup to preserve UDP sources ==="
# Note: Only kill FFmpeg processes on port 8099 if needed
lsof -ti:8099 | xargs kill -9 2>/dev/null || true
sleep 1

# Step 3: Verify UDP sources are still running
echo ""
echo "=== Verifying UDP sources after cleanup ==="
for port in 12350 12351 12352; do
    if check_port $port; then
        echo "✅ Port $port: READY"
    else
        echo "❌ Port $port: NOT READY - please restart"
        exit 1
    fi
done

# Step 4: Start MSwitch with DEBUG logging
echo ""
echo "=== Starting MSwitch Direct Demuxer (DEBUG MODE) ==="
echo ""

rm -f test_mswitchdirect_debug.mts test_mswitchdirect_debug.log

# Use info loglevel and set demuxer options before -i
timeout 45s ./ffmpeg -v info \
  -f mswitchdirect \
  -msw_sources "udp://127.0.0.1:12350,udp://127.0.0.1:12351,udp://127.0.0.1:12352" \
  -msw_port 8099 \
  -i dummy \
  -c:v libx264 -r 30 -preset ultrafast -g 60 -keyint_min 1 -sc_threshold 0 \
  -pix_fmt yuv420p -c:a aac \
  -f mpegts -y test_mswitchdirect_debug.mts 2>&1 | tee test_mswitchdirect_debug.log &

FFMPEG_PID=$!
echo "FFmpeg PID: $FFMPEG_PID"

# Step 5: Wait for startup and check initialization
echo ""
echo "=== Waiting 5s for initialization ==="
sleep 5

# Check if FFmpeg is still running
if ! ps -p $FFMPEG_PID > /dev/null 2>&1; then
    echo ""
    echo "❌ FFmpeg died during startup!"
    echo ""
    echo "=== Last 50 lines of log ==="
    tail -50 test_mswitchdirect_debug.log
    exit 1
fi

echo "✅ FFmpeg is running"

# Check if control port is listening
if check_port 8099; then
    echo "✅ Control port 8099 is listening"
else
    echo "❌ Control port 8099 is NOT listening"
fi

# Step 6: Monitor and switch
echo ""
echo "=== Monitoring logs for MSwitch initialization ==="
grep "MSwitch Direct" test_mswitchdirect_debug.log | tail -20

# Step 7: Perform switches with detailed monitoring
echo ""
echo "=== Waiting additional 5s before first switch ==="
sleep 5

echo ""
echo "=== Switch 1: RED (0) -> GREEN (1) ==="
curl -s -X POST http://localhost:8099/switch/1
echo ""
sleep 7

echo "=== Checking buffer status after switch to GREEN ==="
grep -i "buffer\|thread\|source" test_mswitchdirect_debug.log | tail -20

echo ""
echo "=== Switch 2: GREEN (1) -> BLUE (2) ==="
curl -s -X POST http://localhost:8099/switch/2
echo ""
sleep 7

echo "=== Checking buffer status after switch to BLUE ==="
grep -i "buffer\|thread\|source" test_mswitchdirect_debug.log | tail -20

echo ""
echo "=== Switch 3: BLUE (2) -> RED (0) ==="
curl -s -X POST http://localhost:8099/switch/0
echo ""
sleep 5

echo "=== Final buffer status ==="
grep -i "buffer\|thread\|source" test_mswitchdirect_debug.log | tail -20

# Step 8: Wait for FFmpeg to finish
echo ""
echo "=== Waiting for FFmpeg to complete ==="
wait $FFMPEG_PID
EXIT_CODE=$?

echo ""
echo "FFmpeg exited with code: $EXIT_CODE"

# Step 9: Analyze results
echo ""
echo "========================================="
echo "RESULTS ANALYSIS"
echo "========================================="

if [ -f test_mswitchdirect_debug.mts ]; then
    FILE_SIZE=$(ls -lh test_mswitchdirect_debug.mts | awk '{print $5}')
    echo ""
    echo "✅ Output file created: test_mswitchdirect_debug.mts ($FILE_SIZE)"
    
    # Check for key success indicators in log
    echo ""
    echo "=== Key Log Indicators ==="
    
    echo ""
    echo "1. Demuxer Initialization:"
    grep -i "MSwitch Direct.*Initializ" test_mswitchdirect_debug.log | head -5
    
    echo ""
    echo "2. Sources Opened:"
    grep -i "Opening source" test_mswitchdirect_debug.log | head -10
    
    echo ""
    echo "3. Reader Threads:"
    grep -i "reader.*thread\|thread.*reader" test_mswitchdirect_debug.log | head -10
    
    echo ""
    echo "4. Switch Events:"
    grep -i "switch.*source\|active.*source" test_mswitchdirect_debug.log | grep -v "^#" | head -10
    
    echo ""
    echo "5. Control Server:"
    grep -i "control.*port\|control.*socket\|control.*listen" test_mswitchdirect_debug.log | head -5
    
    echo ""
    echo "6. Packet Buffer Activity:"
    grep -i "packet.*buffer\|buffer.*packet" test_mswitchdirect_debug.log | head -10
    
    echo ""
    echo "=== To play the output ==="
    echo "  ffplay test_mswitchdirect_debug.mts"
    echo ""
    echo "Expected: RED (10s) -> GREEN (7s) -> BLUE (7s) -> RED (5s)"
else
    echo "❌ Output file NOT created"
    echo ""
    echo "=== Last 100 lines of log ==="
    tail -100 test_mswitchdirect_debug.log
fi

echo ""
echo "=== Full debug log saved to: test_mswitchdirect_debug.log ==="
echo ""

