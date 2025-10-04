#!/bin/bash

# Test the new mswitchdirect demuxer
#
# This demuxer opens all sources directly and maintains concurrent
# buffering, solving the filter-based approach's limitations.

echo "========================================="
echo "MSwitch Direct Demuxer Test"
echo "========================================="

cd "$(dirname "$0")/.."

# Step 1: Ensure UDP sources are running
echo ""
echo "=== IMPORTANT: Start UDP sources in 3 separate terminals ===" 
echo ""
echo "Terminal 1:"
echo "./ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i \"aevalsrc=0|0:c=stereo:s=48000\" -pix_fmt yuv420p -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -keyint_min 1 -sc_threshold 0 -b:v 1M -c:a aac -f mpegts \"udp://127.0.0.1:12350?pkt_size=1316\""
echo ""
echo "Terminal 2:"
echo "./ffmpeg -re -f lavfi -i \"color=green:size=1280x720:rate=30\" -f lavfi -i \"sine=frequency=440:sample_rate=48000\" -pix_fmt yuv420p -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -keyint_min 1 -sc_threshold 0 -b:v 1M -c:a aac -f mpegts \"udp://127.0.0.1:12351?pkt_size=1316\""
echo ""
echo "Terminal 3:"
echo "./ffmpeg -re -f lavfi -i \"color=blue:size=1280x720:rate=30\" -f lavfi -i \"sine=frequency=880:sample_rate=48000\" -pix_fmt yuv420p -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -keyint_min 1 -sc_threshold 0 -b:v 1M -c:a aac -f mpegts \"udp://127.0.0.1:12352?pkt_size=1316\""
echo ""
read -p "Press Enter once all 3 sources are running..."

# Step 2: Start MSwitch with demuxer
echo ""
echo "=== Starting MSwitch Direct Demuxer ==="
echo ""

rm -f test_mswitchdirect.mts

timeout 45s ./ffmpeg -loglevel info \
  -f mswitchdirect \
  -sources "udp://127.0.0.1:12350?fifo_size=1024000&overrun_nonfatal=1&timeout=1000000&buffer_size=65536,udp://127.0.0.1:12351?fifo_size=1024000&overrun_nonfatal=1&timeout=1000000&buffer_size=65536,udp://127.0.0.1:12352?fifo_size=1024000&overrun_nonfatal=1&timeout=1000000&buffer_size=65536" \
  -port 8099 \
  -i dummy \
  -c:v libx264 -r 30 -preset ultrafast -g 60 -keyint_min 1 -sc_threshold 0 \
  -pix_fmt yuv420p -c:a aac \
  -f mpegts -y test_mswitchdirect.mts 2>&1 | tee test_mswitchdirect.log &

FFMPEG_PID=$!

# Step 3: Wait for startup
echo "Waiting 10s for startup..."
sleep 10

# Step 4: Send switch commands
echo ""
echo "=== Switch to GREEN (source 1) ==="
curl -s -X POST http://localhost:8099/switch/1
echo ""
sleep 7

echo "=== Switch to BLUE (source 2) ==="
curl -s -X POST http://localhost:8099/switch/2
echo ""
sleep 7

echo "=== Back to RED (source 0) ==="
curl -s -X POST http://localhost:8099/switch/0
echo ""
sleep 5

# Step 5: Check results
echo ""
echo "=== Test complete, checking results ==="
wait $FFMPEG_PID

if [ -f test_mswitchdirect.mts ]; then
    FILE_SIZE=$(ls -lh test_mswitchdirect.mts | awk '{print $5}')
    echo ""
    echo "✅ Output file created: test_mswitchdirect.mts ($FILE_SIZE)"
    echo ""
    echo "Play it with:"
    echo "  ffplay test_mswitchdirect.mts"
    echo ""
    echo "Expected: RED (10s) -> GREEN (7s) -> BLUE (7s) -> RED (5s)"
else
    echo "❌ Output file not created"
fi

echo ""
echo "=== Log file: test_mswitchdirect.log ==="

