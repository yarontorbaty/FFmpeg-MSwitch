#!/bin/bash

echo "=== MSwitch Direct with SRT Relay Server ==="
echo ""
echo "This test uses a dedicated SRT relay server that:"
echo "  - Accepts source connections on port 9000"
echo "  - Provides 3 output streams on ports 12350, 12351, 12352"
echo "  - Handles multiple clients properly"
echo ""

# Check if relay is built
if [ ! -f "srt_relay" ]; then
    echo "Building SRT relay..."
    make || exit 1
fi

echo "Step 1: Starting 3 SRT Relay instances (one per source)..."

# Relay 0: input 9000 → output 12350
./srt_relay 9000 12350 > srt_relay0.log 2>&1 &
RELAY0=$!

# Relay 1: input 9001 → output 12351
./srt_relay 9001 12351 > srt_relay1.log 2>&1 &
RELAY1=$!

# Relay 2: input 9002 → output 12352
./srt_relay 9002 12352 > srt_relay2.log 2>&1 &
RELAY2=$!

echo "  Relay 0 started (PID: $RELAY0) - 9000 → 12350"
echo "  Relay 1 started (PID: $RELAY1) - 9001 → 12351"
echo "  Relay 2 started (PID: $RELAY2) - 9002 → 12352"
echo ""

sleep 1

echo "Step 2: Starting 3 video sources (each publishing to its own relay)..."

# Source 0 → Relay 0 (port 9000)
../ffmpeg -re -f lavfi -i testsrc=size=1280x720:rate=30 \
  -vf "drawtext=text='SRT Source 0':fontsize=72:fontcolor=white:x=(w-text_w)/2:y=(h-text_h)/2" \
  -c:v libx264 -preset ultrafast -tune zerolatency -g 60 \
  -f mpegts "srt://127.0.0.1:9000" > /dev/null 2>&1 &
SRC0=$!

sleep 0.5

# Source 1 → Relay 1 (port 9001)
../ffmpeg -re -f lavfi -i testsrc=size=1280x720:rate=30 \
  -vf "drawtext=text='SRT Source 1':fontsize=72:fontcolor=yellow:x=(w-text_w)/2:y=(h-text_h)/2" \
  -c:v libx264 -preset ultrafast -tune zerolatency -g 60 \
  -f mpegts "srt://127.0.0.1:9001" > /dev/null 2>&1 &
SRC1=$!

sleep 0.5

# Source 2 → Relay 2 (port 9002)
../ffmpeg -re -f lavfi -i testsrc=size=1280x720:rate=30 \
  -vf "drawtext=text='SRT Source 2':fontsize=72:fontcolor=red:x=(w-text_w)/2:y=(h-text_h)/2" \
  -c:v libx264 -preset ultrafast -tune zerolatency -g 60 \
  -f mpegts "srt://127.0.0.1:9002" > /dev/null 2>&1 &
SRC2=$!

echo "  Source 0 started (PID: $SRC0) - publishing to relay 0"
echo "  Source 1 started (PID: $SRC1) - publishing to relay 1"
echo "  Source 2 started (PID: $SRC2) - publishing to relay 2"
echo ""

echo "Waiting 3 seconds for sources to connect..."
sleep 3

echo ""
echo "Step 3: Starting MSwitch Direct (connecting to relay outputs)..."
echo "  Output: udp://127.0.0.1:12360"
echo "  Control: http://localhost:8099"
echo ""
echo "In another terminal:"
echo "  Watch: ffplay udp://127.0.0.1:12360"
echo "  Switch: curl -X POST http://localhost:8099/switch/1"
echo "  Status: curl http://localhost:8099/status"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    kill $SRC0 $SRC1 $SRC2 $RELAY0 $RELAY1 $RELAY2 2>/dev/null
    wait 2>/dev/null
    echo "Done!"
    exit 0
}

trap cleanup INT TERM

# Run mswitchdirect (connecting to relay outputs)
../ffmpeg -y -v info -f mswitchdirect \
  -msw_sources "srt://127.0.0.1:12350?mode=caller,srt://127.0.0.1:12351?mode=caller,srt://127.0.0.1:12352?mode=caller" \
  -msw_port 8099 \
  -msw_auto_failover 1 \
  -msw_health_interval 100 \
  -msw_source_timeout 300 \
  -i dummy \
  -c:v libx264 -r 30 -preset ultrafast -g 60 \
  -f mpegts "udp://127.0.0.1:12360?pkt_size=1316"

cleanup
