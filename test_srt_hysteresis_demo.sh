#!/bin/bash

# SRT Smart Hysteresis DEMO with Visual Overlay + Real-Time Plot
# Perfect for recording video demonstrations

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   SRT SMART HYSTERESIS DEMO (with Real-Time Plot)           ║"
echo "║   Dynamic Bitrate Control + Visual Overlay                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Configuration
CONTAINER_NAME="ffmpeg_hysteresis_demo"
IMAGE_NAME="ffmpeg-x264tcp:latest"
SRT_PORT_INTERNAL=9998  # Internal SRT for bandwidth control
SRT_PORT_EXTERNAL=9999  # External SRT for VLC
UPSHIFT_DELAY_MS=5000

# Phase timings
PHASE_1_DURATION=25
PHASE_2_DURATION=25
PHASE_3_DURATION=25
PHASE_4_DURATION=25

echo "Demo will show:"
echo "  📺  VLC with on-screen bandwidth indicator"
echo "  📊  Real-time plot: Actual vs Target bitrate + Packet loss"
echo "  ⚡  Instant downshift on congestion"
echo "  🕒  Delayed upshift with health checks"
echo ""

# Clean up
docker rm -f $CONTAINER_NAME 2>/dev/null || true
pkill -9 VLC 2>/dev/null || true
pkill -f "plot_bitrate.py" 2>/dev/null || true
sleep 2

# Ensure Big Buck Bunny exists
if [ ! -f /tmp/big_buck_bunny_720p.mp4 ]; then
    echo "Downloading Big Buck Bunny (720p)..."
    curl -L "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4" \
         -o /tmp/big_buck_bunny_720p.mp4
fi

echo "Starting Docker container with visual overlay..."
docker run -d --name $CONTAINER_NAME \
  --cap-add=NET_ADMIN \
  -p ${SRT_PORT_EXTERNAL}:${SRT_PORT_EXTERNAL}/udp \
  -v /tmp/big_buck_bunny_720p.mp4:/input.mp4:ro \
  $IMAGE_NAME \
  bash -c "
set -e

# Start SRT receiver (forwards to external SRT for VLC)
echo 'Starting SRT receiver (relay to VLC)...'
ffmpeg -hide_banner -loglevel error \
  -i 'srt://127.0.0.1:${SRT_PORT_INTERNAL}?mode=listener&latency=3000' \
  -c copy \
  -f mpegts 'srt://0.0.0.0:${SRT_PORT_EXTERNAL}?mode=listener&latency=3000' &
RX_PID=\$!
sleep 3

# Start SRT sender with rate control and visual overlay
echo 'Starting SRT sender with rate control + overlay...'
ffmpeg -loglevel info \
  -re -stream_loop -1 -i /input.mp4 \
  -vf \"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:fontsize=40:fontcolor=white:box=1:boxcolor=black@0.8:boxborderw=12:x=30:y=30:text='SRT Smart Hysteresis Demo':enable=1,
       drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=28:fontcolor=white:box=1:boxcolor=green@0.85:boxborderw=10:x=30:y=100:text='PHASE 1 | Network\\: Excellent (30 Mbps) | Target\\: ~20 Mbps':enable='between(t,0,${PHASE_1_DURATION})',
       drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=28:fontcolor=white:box=1:boxcolor=red@0.85:boxborderw=10:x=30:y=100:text='PHASE 2 | Network\\: CONGESTION (8 Mbps + loss) | Target\\: ~6 Mbps':enable='between(t,${PHASE_1_DURATION},$((PHASE_1_DURATION + PHASE_2_DURATION)))',
       drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=28:fontcolor=white:box=1:boxcolor=orange@0.85:boxborderw=10:x=30:y=100:text='PHASE 3 | Network\\: Recovery (15 Mbps) | Target\\: ~12 Mbps (delayed)':enable='between(t,$((PHASE_1_DURATION + PHASE_2_DURATION)),$((PHASE_1_DURATION + PHASE_2_DURATION + PHASE_3_DURATION)))',
       drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=28:fontcolor=white:box=1:boxcolor=yellow@0.85:boxborderw=10:x=30:y=100:text='PHASE 4 | Network\\: Fluctuation (6 Mbps) | Upshift Cancelled':enable='gte(t,$((PHASE_1_DURATION + PHASE_2_DURATION + PHASE_3_DURATION)))'\" \
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
  -f mpegts 'srt://127.0.0.1:${SRT_PORT_INTERNAL}?latency=3000&enable_stats=1' \
  2>&1 | tee /tmp/demo_sender.log &
TX_PID=\$!

# Keep container running
wait \$TX_PID \$RX_PID
"

echo "Container started: $CONTAINER_NAME"
sleep 5

echo ""
echo "Starting VLC player (SRT caller)..."
echo "VLC will connect to Docker container on localhost:${SRT_PORT_EXTERNAL}"
open -a VLC "srt://127.0.0.1:${SRT_PORT_EXTERNAL}?mode=caller&latency=3000" &
sleep 5

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    STARTING DEMO                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "📺  Watch VLC - On-screen overlay shows network phase"
echo "📊  Graph will appear in new terminal window showing:"
echo "     • Actual bitrate (from encoder)"
echo "     • Target bitrate (from SRT rate control)"
echo "     • Packet loss percentage"
echo ""

# Start plotting in a new terminal window
osascript -e 'tell application "Terminal" to do script "cd '"$(pwd)"' && python3 plot_hysteresis.py"' &

sleep 2

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "PHASE 1: Baseline (30 Mbps, ${PHASE_1_DURATION}s)"
echo "════════════════════════════════════════════════════════════════"

# Apply initial bandwidth on loopback
docker exec $CONTAINER_NAME tc qdisc add dev lo root handle 1: htb default 10
docker exec $CONTAINER_NAME tc class add dev lo parent 1: classid 1:10 htb rate 30mbit ceil 30mbit

sleep ${PHASE_1_DURATION}

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "PHASE 2: Bandwidth Drop (8 Mbps, ${PHASE_2_DURATION}s)"
echo "════════════════════════════════════════════════════════════════"
echo "⚡ INSTANT DOWNSHIFT should occur..."

# Drop to 8 Mbps on loopback
docker exec $CONTAINER_NAME tc qdisc del dev lo root 2>/dev/null || true
docker exec $CONTAINER_NAME tc qdisc add dev lo root handle 1: htb default 10
docker exec $CONTAINER_NAME tc class add dev lo parent 1: classid 1:10 htb rate 8mbit ceil 8mbit
docker exec $CONTAINER_NAME tc qdisc add dev lo parent 1:10 handle 10: netem loss 0.5%

sleep ${PHASE_2_DURATION}

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "PHASE 3: Bandwidth Recovery (15 Mbps, ${PHASE_3_DURATION}s)"
echo "════════════════════════════════════════════════════════════════"
echo "🕒 DELAYED UPSHIFT with health checks..."

# Increase to 15 Mbps on loopback
docker exec $CONTAINER_NAME tc qdisc del dev lo root 2>/dev/null || true
docker exec $CONTAINER_NAME tc qdisc add dev lo root handle 1: htb default 10
docker exec $CONTAINER_NAME tc class add dev lo parent 1: classid 1:10 htb rate 15mbit ceil 15mbit
docker exec $CONTAINER_NAME tc qdisc add dev lo parent 1:10 handle 10: netem loss 0.2%

sleep ${PHASE_3_DURATION}

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "PHASE 4: Upshift Cancellation (${PHASE_4_DURATION}s)"
echo "════════════════════════════════════════════════════════════════"
echo "✗ Upshift should be CANCELLED..."

# Drop to 6 Mbps to trigger cancellation
docker exec $CONTAINER_NAME tc qdisc del dev lo root 2>/dev/null || true
docker exec $CONTAINER_NAME tc qdisc add dev lo root handle 1: htb default 10
docker exec $CONTAINER_NAME tc class add dev lo parent 1: classid 1:10 htb rate 6mbit ceil 6mbit
docker exec $CONTAINER_NAME tc qdisc add dev lo parent 1:10 handle 10: netem loss 1.0%

sleep ${PHASE_4_DURATION}

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    DEMO COMPLETE!                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Show summary
echo "SRT Rate Control Summary:"
docker logs $CONTAINER_NAME 2>&1 | grep -E "SRT Rate Control" | tail -15

echo ""
echo "Plot will auto-close after 110 seconds"
echo "To stop manually: docker rm -f $CONTAINER_NAME && pkill VLC"
echo ""
