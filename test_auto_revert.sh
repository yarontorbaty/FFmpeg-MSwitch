#!/bin/bash
# Test script for auto-revert to preferred source functionality
# Tests priority-based source selection and auto-revert behavior

set -e

echo "======================================"
echo "Auto-Revert Test Script"
echo "======================================"
echo ""
echo "This script tests the auto-revert functionality:"
echo "1. Start with Source 0 (highest priority)"
echo "2. Kill Source 0 → auto-failover to Source 1"
echo "3. Restart Source 0 → auto-revert back to Source 0"
echo ""

# Configuration
SRT_PORT_0=9000
SRT_PORT_1=9001
RECEIVER_PORT=9100
OUTPUT_FILE="test_auto_revert_output.mp4"

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    pkill -f "testsrc.*srt://.*:$SRT_PORT_0" || true
    pkill -f "testsrc.*srt://.*:$SRT_PORT_1" || true
    pkill -f "mswitchdirect.*srt://.*:$RECEIVER_PORT" || true
    sleep 1
}

# Set trap for cleanup
trap cleanup EXIT

# Initial cleanup
cleanup

echo "======================================"
echo "Step 1: Starting SRT sources"
echo "======================================"
echo ""

# Start Source 0 (RED background - highest priority)
echo "Starting Source 0 (RED) on port $SRT_PORT_0..."
./ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=60:size=1280x720:rate=30,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 0 (Priority 1)':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=black@0.5:boxborderw=5,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='%{localtime}':fontsize=36:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2:box=1:boxcolor=black@0.5:boxborderw=5,format=yuv420p,drawbox=color=red@0.3:t=fill" \
    -f lavfi -i "sine=frequency=440:duration=60" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2000k -g 30 -keyint_min 30 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:$SRT_PORT_0?mode=caller&latency=200" \
    > source0_autorevert.log 2>&1 &
SOURCE0_PID=$!
echo "Source 0 PID: $SOURCE0_PID"

# Start Source 1 (GREEN background - lower priority)
echo "Starting Source 1 (GREEN) on port $SRT_PORT_1..."
./ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=60:size=1280x720:rate=30,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 1 (Priority 2)':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=black@0.5:boxborderw=5,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='%{localtime}':fontsize=36:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2:box=1:boxcolor=black@0.5:boxborderw=5,format=yuv420p,drawbox=color=green@0.3:t=fill" \
    -f lavfi -i "sine=frequency=880:duration=60" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2000k -g 30 -keyint_min 30 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:$SRT_PORT_1?mode=caller&latency=200" \
    > source1_autorevert.log 2>&1 &
SOURCE1_PID=$!
echo "Source 1 PID: $SOURCE1_PID"

echo ""
echo "Waiting 3 seconds for sources to initialize..."
sleep 3

echo ""
echo "======================================"
echo "Step 2: Starting receiver with auto-revert"
echo "======================================"
echo ""

# Start receiver with mswitchdirect and auto-revert enabled
echo "Starting receiver with auto-revert enabled..."
echo "Options:"
echo "  - msw_auto_failover: 1"
echo "  - msw_auto_revert: 1"
echo "  - msw_revert_delay: 5000ms"
echo "  - msw_revert_stability_time: 3000ms"
echo "  - msw_source_timeout: 1000ms"
echo ""

./ffmpeg -hide_banner \
    -f mswitchdirect \
    -msw_sources "srt://127.0.0.1:$RECEIVER_PORT?mode=listener&latency=200,srt://127.0.0.1:$((RECEIVER_PORT+1))?mode=listener&latency=200" \
    -msw_port 8099 \
    -msw_auto_failover 1 \
    -msw_auto_revert 1 \
    -msw_revert_delay 5000 \
    -msw_revert_stability_time 3000 \
    -msw_source_timeout 1000 \
    -i dummy \
    -c:v copy -c:a copy \
    -t 60 \
    -f mp4 "$OUTPUT_FILE" \
    > receiver_autorevert.log 2>&1 &
RECEIVER_PID=$!
echo "Receiver PID: $RECEIVER_PID"

echo ""
echo "Waiting 5 seconds for receiver to initialize..."
sleep 5

# Update source URLs to connect to receiver
echo ""
echo "Reconnecting sources to receiver..."
pkill -f "testsrc.*srt://.*:$SRT_PORT_0" || true
pkill -f "testsrc.*srt://.*:$SRT_PORT_1" || true
sleep 2

# Restart sources to connect to receiver
./ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=60:size=1280x720:rate=30,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 0 (Priority 1)':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=black@0.5:boxborderw=5,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='%{localtime}':fontsize=36:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2:box=1:boxcolor=black@0.5:boxborderw=5,format=yuv420p,drawbox=color=red@0.3:t=fill" \
    -f lavfi -i "sine=frequency=440:duration=60" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2000k -g 30 -keyint_min 30 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:$RECEIVER_PORT?mode=caller&latency=200" \
    > source0_autorevert.log 2>&1 &
SOURCE0_PID=$!

./ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=60:size=1280x720:rate=30,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 1 (Priority 2)':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=black@0.5:boxborderw=5,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='%{localtime}':fontsize=36:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2:box=1:boxcolor=black@0.5:boxborderw=5,format=yuv420p,drawbox=color=green@0.3:t=fill" \
    -f lavfi -i "sine=frequency=880:duration=60" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2000k -g 30 -keyint_min 30 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:$((RECEIVER_PORT+1))?mode=caller&latency=200" \
    > source1_autorevert.log 2>&1 &
SOURCE1_PID=$!

echo ""
echo "======================================"
echo "Step 3: Initial Operation (0-10s)"
echo "======================================"
echo "Expected: Source 0 (RED) active"
echo ""
echo "Waiting 10 seconds..."
sleep 10

echo ""
echo "======================================"
echo "Step 4: Kill Source 0 (10s)"
echo "======================================"
echo "Expected: Auto-failover to Source 1 (GREEN) within 1s"
echo ""
echo "Killing Source 0 (PID: $SOURCE0_PID)..."
kill $SOURCE0_PID || true
echo "Source 0 killed at $(date +%T)"
echo ""
echo "Waiting 5 seconds to observe failover..."
sleep 5

echo ""
echo "======================================"
echo "Step 5: Restart Source 0 (15s)"
echo "======================================"
echo "Expected: Auto-revert to Source 0 after 8s (3s stability + 5s delay)"
echo ""
echo "Restarting Source 0..."
./ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=60:size=1280x720:rate=30,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='SOURCE 0 (Priority 1) - RECOVERED':fontsize=48:fontcolor=white:x=(w-text_w)/2:y=50:box=1:boxcolor=black@0.5:boxborderw=5,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='%{localtime}':fontsize=36:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2:box=1:boxcolor=black@0.5:boxborderw=5,format=yuv420p,drawbox=color=red@0.3:t=fill" \
    -f lavfi -i "sine=frequency=440:duration=60" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2000k -g 30 -keyint_min 30 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:$RECEIVER_PORT?mode=caller&latency=200" \
    > source0_autorevert.log 2>&1 &
SOURCE0_PID=$!
echo "Source 0 restarted at $(date +%T) (PID: $SOURCE0_PID)"
echo ""
echo "Waiting 12 seconds for auto-revert (3s stability + 5s delay + buffer)..."
sleep 12

echo ""
echo "======================================"
echo "Step 6: Verify auto-revert occurred"
echo "======================================"
echo ""

# Check logs for auto-revert
if grep -q "AUTO-REVERT" receiver_autorevert.log; then
    echo "✅ AUTO-REVERT detected in logs!"
    echo ""
    echo "Auto-revert events:"
    grep "AUTO-REVERT" receiver_autorevert.log
else
    echo "❌ No AUTO-REVERT found in logs"
fi

echo ""
echo "Continuing for 10 more seconds to observe stability..."
sleep 10

echo ""
echo "======================================"
echo "Test Complete!"
echo "======================================"
echo ""
echo "Stopping receiver..."
kill $RECEIVER_PID || true

echo ""
echo "======================================"
echo "Test Results Summary"
echo "======================================"
echo ""

# Analyze logs
echo "Failover events:"
grep -E "AUTO-FAILOVER|AUTO-REVERT" receiver_autorevert.log || echo "  None found"

echo ""
echo "Health events:"
grep -E "unhealthy|recovered" receiver_autorevert.log | head -20 || echo "  None found"

echo ""
echo "Output file: $OUTPUT_FILE"
if [ -f "$OUTPUT_FILE" ]; then
    FILE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
    echo "File size: $FILE_SIZE"
    echo ""
    echo "You can play the output to visually verify:"
    echo "  ffplay $OUTPUT_FILE"
    echo ""
    echo "Expected visual pattern:"
    echo "  0-10s:  RED screen (Source 0)"
    echo "  10-23s: GREEN screen (Source 1 after failover)"
    echo "  23s+:   RED screen (Source 0 after auto-revert)"
else
    echo "Warning: Output file not created"
fi

echo ""
echo "Log files:"
echo "  - receiver_autorevert.log"
echo "  - source0_autorevert.log"
echo "  - source1_autorevert.log"
echo ""
echo "======================================"
echo "Test script finished"
echo "======================================"

