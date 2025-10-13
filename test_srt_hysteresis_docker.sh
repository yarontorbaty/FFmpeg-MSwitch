#!/bin/bash

# Test SRT Smart Hysteresis with Docker + netem
# Demonstrates instant downshift and delayed upshift with real network simulation

set -e

echo "========================================"
echo "SRT Smart Hysteresis Test (Docker)"
echo "========================================"
echo ""

# Configuration
CONTAINER_NAME="ffmpeg_hysteresis_test"
IMAGE_NAME="ffmpeg-x264tcp:latest"
SRT_PORT=9999
HTTP_PORT=8080
UPSHIFT_DELAY_MS=5000  # 5-second delay for upshift

# Phase timings
PHASE_1_DURATION=20  # Baseline at high bandwidth
PHASE_2_DURATION=20  # Low bandwidth (instant downshift)
PHASE_3_DURATION=15  # Recovery (delayed upshift with health checks)
PHASE_4_DURATION=15  # Final high bandwidth

echo "Test will demonstrate:"
echo "  ⚡ INSTANT downshift when bandwidth drops"
echo "  🕒 DELAYED upshift (${UPSHIFT_DELAY_MS}ms) with health checks"
echo "  ✗ Upshift cancellation if bandwidth fluctuates"
echo ""

# Clean up
docker rm -f $CONTAINER_NAME 2>/dev/null || true
pkill -9 VLC 2>/dev/null || true

# Ensure Big Buck Bunny exists
if [ ! -f /tmp/big_buck_bunny_720p.mp4 ]; then
    echo "Downloading Big Buck Bunny (720p)..."
    curl -L "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4" \
         -o /tmp/big_buck_bunny_720p.mp4
fi

echo ""
echo "Starting Docker container with SRT + Smart Hysteresis..."
docker run -d --name $CONTAINER_NAME \
  --cap-add=NET_ADMIN \
  -p ${SRT_PORT}:${SRT_PORT}/udp \
  -p ${HTTP_PORT}:${HTTP_PORT}/tcp \
  -v /tmp/big_buck_bunny_720p.mp4:/input.mp4:ro \
  $IMAGE_NAME \
  bash -c "
    # Start FFmpeg in background
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
      -http_control_enable 1 \
      -http_control_port ${HTTP_PORT} \
      -f mpegts 'srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=3000&streamid=#!::r=test,m=publish,enable_stats=1&connect_timeout=5000&tlpktdrop=1' &
    FFMPEG_PID=\\\$!
    
    # Keep container running
    wait \\\$FFMPEG_PID
  "

echo "Container started: $CONTAINER_NAME"
echo "Waiting for encoder initialization..."
sleep 5

echo ""
echo "Starting VLC player..."
open -a VLC "srt://127.0.0.1:${SRT_PORT}?mode=caller&latency=3000" &
sleep 3

echo ""
echo "========================================"
echo "PHASE 1: Baseline (30 Mbps, ${PHASE_1_DURATION}s)"
echo "========================================"
echo "High bandwidth, encoder should run at ~20 Mbps"
echo ""

# No bandwidth limit for baseline
docker exec $CONTAINER_NAME tc qdisc del dev eth0 root 2>/dev/null || true

sleep ${PHASE_1_DURATION}

# Check encoding bitrate
docker logs $CONTAINER_NAME 2>&1 | tail -1 | grep -oE "bitrate=[0-9.]+kbits" || echo "No stats yet"

echo ""
echo "========================================"
echo "PHASE 2: Bandwidth Drop (8 Mbps, ${PHASE_2_DURATION}s)"
echo "========================================"
echo "⚡ Simulating network congestion..."
echo "Expected: INSTANT DOWNSHIFT to ~6-7 Mbps"
echo ""

# Apply bandwidth limit: 8 Mbps
docker exec $CONTAINER_NAME tc qdisc add dev eth0 root handle 1: htb default 10
docker exec $CONTAINER_NAME tc class add dev eth0 parent 1: classid 1:10 htb rate 8mbit ceil 8mbit
docker exec $CONTAINER_NAME tc qdisc add dev eth0 parent 1:10 handle 10: netem loss 0.5% delay 50ms

echo "Network limited to 8 Mbps with 0.5% loss"
sleep 3

# Monitor for downshift message
echo "Waiting for SRT to detect congestion and trigger downshift..."
for i in {1..10}; do
    sleep 1
    NEW_DOWNSHIFT=$(docker logs $CONTAINER_NAME 2>&1 | grep -E "INSTANT DOWNSHIFT" | tail -1)
    if [ ! -z "$NEW_DOWNSHIFT" ]; then
        echo "✓ DETECTED: $NEW_DOWNSHIFT"
        break
    fi
done

echo ""
echo "Encoder is now at lower bitrate (protecting against congestion)"
echo "Waiting ${PHASE_2_DURATION}s..."
sleep $((PHASE_2_DURATION - 5))

# Show current bitrate
docker logs $CONTAINER_NAME 2>&1 | tail -1 | grep -oE "bitrate=[0-9.]+kbits" || echo "Encoding..."

echo ""
echo "========================================"
echo "PHASE 3: Bandwidth Recovery (15 Mbps, ${PHASE_3_DURATION}s)"
echo "========================================"
echo "🕒 Improving bandwidth gradually..."
echo "Expected: Delayed upshift with health checks"
echo ""

# Increase to 15 Mbps - delete and recreate qdisc
docker exec $CONTAINER_NAME tc qdisc del dev eth0 root 2>/dev/null || true
docker exec $CONTAINER_NAME tc qdisc add dev eth0 root handle 1: htb default 10
docker exec $CONTAINER_NAME tc class add dev eth0 parent 1: classid 1:10 htb rate 15mbit ceil 15mbit
docker exec $CONTAINER_NAME tc qdisc add dev eth0 parent 1:10 handle 10: netem loss 0.2%

echo "Network improved to 15 Mbps"
echo ""
echo "Upshift should be PENDING (not instant)..."
echo "Health checks will verify bandwidth stability for ${UPSHIFT_DELAY_MS}ms"
echo ""

# Monitor upshift process
for i in {1..30}; do
    sleep 0.5
    
    # Look for upshift-related messages
    UPSHIFT_MSG=$(docker logs $CONTAINER_NAME 2>&1 | grep -E "(UPSHIFT PENDING|HEALTH CHECK|UPSHIFT APPROVED)" | tail -1)
    TIMESTAMP=$(date +%T)
    
    if [ ! -z "$UPSHIFT_MSG" ] && [[ "$UPSHIFT_MSG" != "$LAST_MSG" ]]; then
        echo "[$TIMESTAMP] $UPSHIFT_MSG"
        LAST_MSG="$UPSHIFT_MSG"
    fi
done

echo ""
echo "Waiting for health checks to complete..."
sleep 5

# Check if upshift was approved
UPSHIFT_APPROVED=$(docker logs $CONTAINER_NAME 2>&1 | grep -E "UPSHIFT APPROVED" | tail -1)
if [ ! -z "$UPSHIFT_APPROVED" ]; then
    echo "✓ SUCCESS: $UPSHIFT_APPROVED"
else
    echo "⏳ Still pending or health checks incomplete"
fi

echo ""
echo "========================================"
echo "PHASE 4: Test Upshift Cancellation"
echo "========================================"
echo "Dropping bandwidth DURING upshift delay..."
echo "Expected: Upshift timer should RESET"
echo ""

# Drop to 6 Mbps to trigger cancellation - delete and recreate
docker exec $CONTAINER_NAME tc qdisc del dev eth0 root 2>/dev/null || true
docker exec $CONTAINER_NAME tc qdisc add dev eth0 root handle 1: htb default 10
docker exec $CONTAINER_NAME tc class add dev eth0 parent 1: classid 1:10 htb rate 6mbit ceil 6mbit
docker exec $CONTAINER_NAME tc qdisc add dev eth0 parent 1:10 handle 10: netem loss 1.0%

echo "Network dropped to 6 Mbps (simulating fluctuation)"
sleep 2

# Look for cancellation message
CANCEL_MSG=$(docker logs $CONTAINER_NAME 2>&1 | grep -E "(Cancelling pending upshift|INSTANT DOWNSHIFT)" | tail -2)
echo ""
echo "Cancellation events:"
echo "$CANCEL_MSG"

sleep 10

echo ""
echo "========================================"
echo "PHASE 5: Final Recovery (25 Mbps, ${PHASE_4_DURATION}s)"
echo "========================================"
echo "Restoring full bandwidth..."
echo ""

# Remove all limits
docker exec $CONTAINER_NAME tc qdisc del dev eth0 root 2>/dev/null || true

echo "Network restored to full speed"
echo "Upshift timer restarted, waiting ${UPSHIFT_DELAY_MS}ms..."
echo ""

# Monitor final upshift
for i in {1..20}; do
    sleep 0.5
    UPSHIFT_MSG=$(docker logs $CONTAINER_NAME 2>&1 | grep -E "(UPSHIFT PENDING|HEALTH CHECK|UPSHIFT APPROVED)" | tail -1)
    TIMESTAMP=$(date +%T)
    if [ ! -z "$UPSHIFT_MSG" ] && [[ "$UPSHIFT_MSG" != "$LAST_MSG_FINAL" ]]; then
        echo "[$TIMESTAMP] $UPSHIFT_MSG"
        LAST_MSG_FINAL="$UPSHIFT_MSG"
    fi
done

echo ""
echo "========================================"
echo "Test Complete!"
echo "========================================"
echo ""
echo "Summary of Smart Hysteresis Behavior:"
echo ""

# Count events
DOWNSHIFTS=$(docker logs $CONTAINER_NAME 2>&1 | grep -c "INSTANT DOWNSHIFT" || echo "0")
UPSHIFT_PENDING=$(docker logs $CONTAINER_NAME 2>&1 | grep -c "UPSHIFT PENDING" || echo "0")
UPSHIFT_APPROVED=$(docker logs $CONTAINER_NAME 2>&1 | grep -c "UPSHIFT APPROVED" || echo "0")
UPSHIFT_CANCELLED=$(docker logs $CONTAINER_NAME 2>&1 | grep -c "Cancelling pending upshift" || echo "0")
HEALTH_CHECKS=$(docker logs $CONTAINER_NAME 2>&1 | grep -c "HEALTH CHECK" || echo "0")

echo "  ⚡ Instant downshifts: $DOWNSHIFTS"
echo "  🕒 Upshift pending events: $UPSHIFT_PENDING"
echo "  ✓ Upshift approved: $UPSHIFT_APPROVED"
echo "  ✗ Upshift cancelled: $UPSHIFT_CANCELLED"
echo "  ❤ Health checks performed: $HEALTH_CHECKS"
echo ""

echo "=== Recent Hysteresis Events ==="
docker logs $CONTAINER_NAME 2>&1 | grep -E "(INSTANT DOWNSHIFT|UPSHIFT PENDING|HEALTH CHECK|UPSHIFT APPROVED|Cancelling)" | tail -15

echo ""
echo "Full logs saved. To review:"
echo "  docker logs $CONTAINER_NAME > /tmp/full_hysteresis.log"
echo ""
echo "Press ENTER to cleanup and exit..."
read

# Cleanup
docker rm -f $CONTAINER_NAME
pkill -9 VLC 2>/dev/null || true

echo ""
echo "Cleanup complete!"

