#!/bin/bash

# Test SRT rate control with STATIC bandwidth (no mid-stream changes)
# This avoids disrupting the SRT connection with tc modifications

set -e

echo "========================================"
echo "SRT Rate Control Test (Static Bandwidth)"
echo "========================================"
echo ""

# Configuration
CONTAINER_NAME="ffmpeg_static_test"
IMAGE_NAME="ffmpeg-x264tcp:latest"
SRT_PORT=9999
HTTP_PORT=8080
TEST_DURATION=60  # seconds

# Choose bandwidth scenario
echo "Select bandwidth scenario:"
echo "1) High bandwidth (30 Mbps) - encoder should use ~20 Mbps"
echo "2) Medium bandwidth (15 Mbps) - encoder should adapt to ~12 Mbps"
echo "3) Low bandwidth (8 Mbps) - encoder should adapt to ~6 Mbps"
echo ""
read -p "Enter choice (1-3): " CHOICE

case $CHOICE in
    1)
        BANDWIDTH="30mbit"
        LOSS="0.1%"
        EXPECTED="~20 Mbps"
        ;;
    2)
        BANDWIDTH="15mbit"
        LOSS="0.3%"
        EXPECTED="~12 Mbps"
        ;;
    3)
        BANDWIDTH="8mbit"
        LOSS="0.5%"
        EXPECTED="~6 Mbps"
        ;;
    *)
        echo "Invalid choice, using medium bandwidth"
        BANDWIDTH="15mbit"
        LOSS="0.3%"
        EXPECTED="~12 Mbps"
        ;;
esac

echo ""
echo "Configuration:"
echo "  Bandwidth: $BANDWIDTH"
echo "  Loss: $LOSS"
echo "  Expected encoder bitrate: $EXPECTED"
echo ""

# Clean up
docker rm -f $CONTAINER_NAME 2>/dev/null || true
pkill -9 VLC 2>/dev/null || true
sleep 2

# Ensure Big Buck Bunny exists
if [ ! -f /tmp/big_buck_bunny_720p.mp4 ]; then
    echo "Downloading Big Buck Bunny (720p)..."
    curl -L "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4" \
         -o /tmp/big_buck_bunny_720p.mp4
fi

echo ""
echo "Starting Docker container with SRT rate control..."
docker run -d --name $CONTAINER_NAME \
  --cap-add=NET_ADMIN \
  -p ${SRT_PORT}:${SRT_PORT}/udp \
  -p ${HTTP_PORT}:${HTTP_PORT}/tcp \
  -v /tmp/big_buck_bunny_720p.mp4:/input.mp4:ro \
  $IMAGE_NAME \
  bash -c "
    # Apply bandwidth limit BEFORE starting FFmpeg
    tc qdisc add dev eth0 root handle 1: htb default 10
    tc class add dev eth0 parent 1: classid 1:10 htb rate $BANDWIDTH ceil $BANDWIDTH
    tc qdisc add dev eth0 parent 1:10 handle 10: netem loss $LOSS
    
    # Now start FFmpeg with the network already configured
    ffmpeg -loglevel info \
      -re -stream_loop -1 -i /input.mp4 \
      -c:v libx264 \
      -preset ultrafast \
      -tune zerolatency \
      -b:v 20000k \
      -g 60 \
      -srt_rate_control 1 \
      -enable_encoder_restart 1 \
      -srt_min_bitrate 3000000 \
      -srt_max_bitrate 25000000 \
      -srt_upshift_delay_ms 5000 \
      -http_control_enable 1 \
      -http_control_port ${HTTP_PORT} \
      -f mpegts 'srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=3000&streamid=#!::r=test,m=publish,enable_stats=1&connect_timeout=5000&tlpktdrop=1'
  "

echo "Container started: $CONTAINER_NAME"
echo "Waiting for encoder initialization..."
sleep 5

echo ""
echo "Starting VLC player..."
open -a VLC "srt://127.0.0.1:${SRT_PORT}?mode=caller&latency=3000" &
sleep 5

echo ""
echo "========================================"
echo "Monitoring for ${TEST_DURATION} seconds..."
echo "========================================"
echo "Watch VLC - encoder should adapt to network conditions"
echo ""

# Monitor
for i in $(seq 1 $((TEST_DURATION / 5))); do
    sleep 5
    
    # Get encoding stats
    STATS=$(docker logs $CONTAINER_NAME 2>&1 | grep "frame=" | tail -1)
    SRT_LOG=$(docker logs $CONTAINER_NAME 2>&1 | grep -E "SRT Rate Control|ENCODER RESTART" | tail -1)
    TIMESTAMP=$(date +%T)
    
    if [ ! -z "$STATS" ]; then
        FRAME=$(echo "$STATS" | grep -oE "frame=[[:space:]]*[0-9]+" | grep -oE "[0-9]+")
        FPS=$(echo "$STATS" | grep -oE "fps=[[:space:]]*[0-9.]+" | grep -oE "[0-9.]+")
        BITRATE=$(echo "$STATS" | grep -oE "bitrate=[[:space:]]*[0-9.]+[kmg]bits" | cut -d'=' -f2)
        
        echo "[$TIMESTAMP] Frame: $FRAME | FPS: $FPS | Bitrate: $BITRATE"
    fi
    
    if [ ! -z "$SRT_LOG" ]; then
        echo "         └─ $SRT_LOG"
    fi
done

echo ""
echo "========================================"
echo "Test Complete!"
echo "========================================"
echo ""

# Show final stats
echo "Final 10 lines of encoder output:"
docker logs $CONTAINER_NAME 2>&1 | grep -E "frame=|SRT Rate Control|ENCODER RESTART" | tail -10

echo ""
echo "SRT rate control summary:"
docker logs $CONTAINER_NAME 2>&1 | grep "SRT Rate Control" | tail -5

echo ""
echo "To view full logs: docker logs $CONTAINER_NAME"
echo "To stop: docker rm -f $CONTAINER_NAME && pkill VLC"
echo ""

