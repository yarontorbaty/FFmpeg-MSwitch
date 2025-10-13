#!/bin/bash

# Simple Docker + VLC test WITHOUT bandwidth changes
# Just to verify VLC can receive the stream continuously

set -e

echo "========================================"
echo "Simple Docker → VLC Test"
echo "========================================"
echo ""

# Configuration
CONTAINER_NAME="ffmpeg_simple_test"
IMAGE_NAME="ffmpeg-x264tcp:latest"
SRT_PORT=9999

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
echo "Starting Docker container..."
docker run -d --name $CONTAINER_NAME \
  -p ${SRT_PORT}:${SRT_PORT}/udp \
  -v /tmp/big_buck_bunny_720p.mp4:/input.mp4:ro \
  $IMAGE_NAME \
  ffmpeg -loglevel info \
    -re -stream_loop -1 -i /input.mp4 \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -b:v 10000k \
    -g 60 \
    -f mpegts "srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=3000&connect_timeout=5000&tlpktdrop=1"

echo "Container started: $CONTAINER_NAME"
echo "Waiting for encoder initialization..."
sleep 5

echo ""
echo "Starting VLC player..."
open -a VLC "srt://127.0.0.1:${SRT_PORT}?mode=caller&latency=3000" &
sleep 3

echo ""
echo "========================================"
echo "Monitoring for 60 seconds..."
echo "========================================"
echo "VLC should play continuously without stopping"
echo ""

# Monitor for 60 seconds
for i in {1..12}; do
    sleep 5
    
    # Get current frame count
    FRAME_INFO=$(docker logs $CONTAINER_NAME 2>&1 | grep "frame=" | tail -1)
    TIMESTAMP=$(date +%T)
    
    if [ ! -z "$FRAME_INFO" ]; then
        # Extract frame number and bitrate
        FRAME_NUM=$(echo "$FRAME_INFO" | grep -oE "frame=[[:space:]]*[0-9]+" | grep -oE "[0-9]+")
        BITRATE=$(echo "$FRAME_INFO" | grep -oE "bitrate=[[:space:]]*[0-9.]+[kmg]bits" | grep -oE "[0-9.]+")
        FPS=$(echo "$FRAME_INFO" | grep -oE "fps=[[:space:]]*[0-9.]+" | grep -oE "[0-9.]+")
        
        echo "[$TIMESTAMP] Frame: $FRAME_NUM | FPS: $FPS | Bitrate: ${BITRATE}kbps"
    fi
done

echo ""
echo "========================================"
echo "Test complete!"
echo "========================================"
echo ""

# Final stats
echo "Final encoding stats:"
docker logs $CONTAINER_NAME 2>&1 | grep "frame=" | tail -3

echo ""
echo "To view full logs: docker logs $CONTAINER_NAME"
echo "To stop: docker rm -f $CONTAINER_NAME && pkill VLC"
echo ""

