#!/bin/bash

# SRT Smart Hysteresis Test with Relay Pattern
# Uses internal SRT connection (sender → receiver) inside Docker
# Only UDP crosses to host VLC

set -e

echo "========================================"
echo "SRT Smart Hysteresis Test (Relay Pattern)"
echo "========================================"
echo ""

# Configuration
CONTAINER_NAME="ffmpeg_hysteresis_relay"
IMAGE_NAME="ffmpeg-x264tcp:latest"
SRT_PORT=9999
UDP_PORT=5400
UPSHIFT_DELAY_MS=5000

# Phase timings
PHASE_1_DURATION=20
PHASE_2_DURATION=20
PHASE_3_DURATION=15
PHASE_4_DURATION=15

echo "Test will demonstrate:"
echo "  ⚡ INSTANT downshift when bandwidth drops"
echo "  🕒 DELAYED upshift (${UPSHIFT_DELAY_MS}ms) with health checks"
echo "  ✗ Upshift cancellation if bandwidth fluctuates"
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

# Get host IP
HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "192.168.1.100")
echo "Host IP: $HOST_IP"
echo ""

echo "Starting Docker container..."
docker run -d --name $CONTAINER_NAME \
  --cap-add=NET_ADMIN \
  -v /tmp/big_buck_bunny_720p.mp4:/input.mp4:ro \
  $IMAGE_NAME \
  bash -c "
set -e

# Start SRT receiver (forwards to UDP)
echo 'Starting SRT receiver...'
ffmpeg -hide_banner -loglevel error \
  -i 'srt://127.0.0.1:${SRT_PORT}?mode=listener&latency=3000' \
  -c copy \
  -f mpegts 'udp://${HOST_IP}:${UDP_PORT}?pkt_size=1316' &
RX_PID=\$!
sleep 3

# Start SRT sender with rate control
echo 'Starting SRT sender with rate control...'
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
  -srt_upshift_delay_ms ${UPSHIFT_DELAY_MS} \
  -c:a aac -b:a 128k \
  -f mpegts 'srt://127.0.0.1:${SRT_PORT}?latency=3000&enable_stats=1' &
TX_PID=\$!

# Keep container running
wait \$TX_PID \$RX_PID
"

echo "Container started: $CONTAINER_NAME"
sleep 5

echo ""
echo "Starting VLC player..."
open -a VLC "udp://@:${UDP_PORT}" &
sleep 3

echo ""
echo "========================================"
echo "PHASE 1: Baseline (30 Mbps, ${PHASE_1_DURATION}s)"
echo "========================================"
echo "High bandwidth, encoder should run at ~20 Mbps"
echo ""

# Apply initial bandwidth on loopback
docker exec $CONTAINER_NAME tc qdisc add dev lo root handle 1: htb default 10
docker exec $CONTAINER_NAME tc class add dev lo parent 1: classid 1:10 htb rate 30mbit ceil 30mbit

sleep ${PHASE_1_DURATION}

echo ""
echo "========================================"
echo "PHASE 2: Bandwidth Drop (8 Mbps, ${PHASE_2_DURATION}s)"
echo "========================================"
echo "⚡ Simulating network congestion..."
echo "Expected: INSTANT DOWNSHIFT to ~6-7 Mbps"
echo ""

# Drop to 8 Mbps on loopback
docker exec $CONTAINER_NAME tc qdisc del dev lo root 2>/dev/null || true
docker exec $CONTAINER_NAME tc qdisc add dev lo root handle 1: htb default 10
docker exec $CONTAINER_NAME tc class add dev lo parent 1: classid 1:10 htb rate 8mbit ceil 8mbit
docker exec $CONTAINER_NAME tc qdisc add dev lo parent 1:10 handle 10: netem loss 0.5%

echo "Network limited to 8 Mbps with 0.5% loss"
sleep 3

echo "Waiting for SRT to detect congestion and trigger downshift..."
for i in {1..10}; do
    sleep 1
    DOWNSHIFT=$(docker logs $CONTAINER_NAME 2>&1 | grep -E "INSTANT DOWNSHIFT" | tail -1)
    if [ ! -z "$DOWNSHIFT" ]; then
        echo "✓ Downshift detected!"
        break
    fi
done

echo ""
echo "Encoder is now at lower bitrate (protecting against congestion)"
echo "Waiting ${PHASE_2_DURATION}s..."
sleep $((PHASE_2_DURATION - 13))

echo "Encoding..."
sleep 10

echo ""
echo "========================================"
echo "PHASE 3: Bandwidth Recovery (15 Mbps, ${PHASE_3_DURATION}s)"
echo "========================================"
echo "🕒 Improving bandwidth gradually..."
echo "Expected: Delayed upshift with health checks"
echo ""

# Increase to 15 Mbps on loopback
docker exec $CONTAINER_NAME tc qdisc del dev lo root 2>/dev/null || true
docker exec $CONTAINER_NAME tc qdisc add dev lo root handle 1: htb default 10
docker exec $CONTAINER_NAME tc class add dev lo parent 1: classid 1:10 htb rate 15mbit ceil 15mbit
docker exec $CONTAINER_NAME tc qdisc add dev lo parent 1:10 handle 10: netem loss 0.2%

echo "Network improved to 15 Mbps"
echo ""
echo "Upshift should be PENDING (not instant)..."
echo "Health checks will verify bandwidth stability for ${UPSHIFT_DELAY_MS}ms"
echo ""

# Monitor upshift process
for i in {1..15}; do
    sleep 1
    
    UPSHIFT_MSG=$(docker logs $CONTAINER_NAME 2>&1 | grep -E "(UPSHIFT PENDING|HEALTH CHECK|UPSHIFT APPROVED)" | tail -1)
    TIMESTAMP=$(date +%T)
    
    if [ ! -z "$UPSHIFT_MSG" ] && [[ "$UPSHIFT_MSG" != "$LAST_MSG" ]]; then
        echo "[$TIMESTAMP] $UPSHIFT_MSG"
        LAST_MSG="$UPSHIFT_MSG"
    fi
done

echo ""
echo "========================================"
echo "PHASE 4: Test Upshift Cancellation (${PHASE_4_DURATION}s)"
echo "========================================"
echo "Dropping bandwidth DURING upshift delay..."
echo "Expected: Upshift timer should RESET"
echo ""

# Drop to 6 Mbps to trigger cancellation
docker exec $CONTAINER_NAME tc qdisc del dev lo root 2>/dev/null || true
docker exec $CONTAINER_NAME tc qdisc add dev lo root handle 1: htb default 10
docker exec $CONTAINER_NAME tc class add dev lo parent 1: classid 1:10 htb rate 6mbit ceil 6mbit
docker exec $CONTAINER_NAME tc qdisc add dev lo parent 1:10 handle 10: netem loss 1.0%

echo "Network dropped to 6 Mbps (simulating fluctuation)"
sleep 2

CANCEL_MSG=$(docker logs $CONTAINER_NAME 2>&1 | grep -E "(Cancelling pending upshift|INSTANT DOWNSHIFT)" | tail -2)
echo ""
echo "Cancellation events:"
echo "$CANCEL_MSG"

sleep ${PHASE_4_DURATION}

echo ""
echo "========================================"
echo "TEST COMPLETE!"
echo "========================================"
echo ""

# Show summary
echo "SRT Rate Control Events:"
docker logs $CONTAINER_NAME 2>&1 | grep -E "SRT Rate Control" | tail -10

echo ""
echo "To view full logs: docker logs $CONTAINER_NAME"
echo "To stop: docker rm -f $CONTAINER_NAME && pkill VLC"
echo ""

