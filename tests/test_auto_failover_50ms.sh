#!/bin/bash

# Test auto-failover with 50ms detection
# This test will:
# 1. Start 3 UDP sources
# 2. Start FFmpeg with mswitchdirect (50ms failover)
# 3. Kill source 0 after 5 seconds
# 4. Observe auto-failover to source 1
# 5. Check that output continues

set -e

echo "=== Auto-Failover Test (50ms detection) ==="
echo ""

# Clean up any existing processes
echo "Cleaning up existing processes..."
pkill -9 ffmpeg 2>/dev/null || true
sleep 1

# Check if sources are running
if ! lsof -i :12350 > /dev/null 2>&1; then
    echo "ERROR: Source 0 (port 12350) is not running!"
    echo "Please start it in a separate terminal:"
    echo "  ffmpeg -re -f lavfi -i testsrc=size=1280x720:rate=30 -f lavfi -i sine -pix_fmt yuv420p -c:v libx264 -preset ultrafast -tune zerolatency -g 30 -keyint_min 1 -sc_threshold 0 -b:v 2M -c:a aac -f mpegts 'udp://127.0.0.1:12350?pkt_size=1316'"
    exit 1
fi

if ! lsof -i :12351 > /dev/null 2>&1; then
    echo "ERROR: Source 1 (port 12351) is not running!"
    echo "Please start it in a separate terminal."
    exit 1
fi

if ! lsof -i :12352 > /dev/null 2>&1; then
    echo "ERROR: Source 2 (port 12352) is not running!"
    echo "Please start it in a separate terminal."
    exit 1
fi

echo "✓ All 3 sources are running"
echo ""

# Start FFmpeg with mswitchdirect
echo "Starting FFmpeg with 50ms auto-failover..."
./ffmpeg -y \
  -v info \
  -f mswitchdirect \
  -msw_sources "udp://127.0.0.1:12350,udp://127.0.0.1:12351,udp://127.0.0.1:12352" \
  -msw_port 8099 \
  -msw_health_interval 50 \
  -msw_source_timeout 50 \
  -i dummy \
  -c:v libx264 -r 30 -preset ultrafast -g 60 -keyint_min 1 -sc_threshold 0 \
  -pix_fmt yuv420p \
  -t 20 \
  -f mpegts test_auto_failover_50ms.mts \
  > auto_failover_50ms.log 2>&1 &

FFMPEG_PID=$!
echo "FFmpeg PID: $FFMPEG_PID"
echo ""

# Wait for initialization
echo "Waiting 3 seconds for initialization..."
sleep 3

# Kill source 0 to trigger failover
echo "🔪 Killing source 0 (port 12350) to trigger failover..."
SOURCE_PID=$(lsof -ti:12350)
if [ -n "$SOURCE_PID" ]; then
    kill -9 $SOURCE_PID
    echo "✓ Source 0 killed (PID: $SOURCE_PID)"
else
    echo "⚠️  Could not find source 0 process"
fi
echo ""

# Wait for failover and continued processing
echo "Waiting 5 seconds for failover and continued processing..."
sleep 5

# Check if FFmpeg is still running
if ps -p $FFMPEG_PID > /dev/null 2>&1; then
    echo "✓ FFmpeg still running after failover"
else
    echo "❌ FFmpeg stopped after failover!"
fi
echo ""

# Wait for test to complete
echo "Waiting for test to complete (12 more seconds)..."
wait $FFMPEG_PID 2>/dev/null || true

echo ""
echo "=== Test Results ==="
echo ""

# Check log for failover
echo "Checking for AUTO-FAILOVER in log..."
if grep -q "AUTO-FAILOVER" auto_failover_50ms.log; then
    echo "✓ Auto-failover detected in log:"
    grep "AUTO-FAILOVER" auto_failover_50ms.log | head -3
else
    echo "❌ No auto-failover found in log"
fi
echo ""

# Check for source changes
echo "Checking for source changes..."
if grep -q "Source changed" auto_failover_50ms.log; then
    echo "✓ Source changes detected:"
    grep "Source changed" auto_failover_50ms.log | head -5
else
    echo "⚠️  No source changes found"
fi
echo ""

# Check output file
if [ -f test_auto_failover_50ms.mts ]; then
    SIZE=$(stat -f%z test_auto_failover_50ms.mts 2>/dev/null || stat -c%s test_auto_failover_50ms.mts 2>/dev/null)
    echo "✓ Output file created: test_auto_failover_50ms.mts ($SIZE bytes)"
    if [ "$SIZE" -gt 100000 ]; then
        echo "✓ Output file size looks good (>100KB)"
    else
        echo "⚠️  Output file might be too small"
    fi
else
    echo "❌ Output file not created!"
fi
echo ""

echo "Full log saved to: auto_failover_50ms.log"
echo "Output file: test_auto_failover_50ms.mts"
echo ""
echo "To view full log:"
echo "  cat auto_failover_50ms.log"
echo ""
echo "To play output:"
echo "  ffplay test_auto_failover_50ms.mts"

