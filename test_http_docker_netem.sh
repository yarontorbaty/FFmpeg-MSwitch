#!/bin/bash
#
# HTTP Encoder Control Test with Docker + netem
# Tests dynamic bitrate control via HTTP commands while simulating network conditions
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   HTTP ENCODER CONTROL + DOCKER + NETEM TEST                 ║"
echo "║   Dynamic Bitrate via HTTP + Network Simulation              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

VLC_PORT=5400
SRT_PORT=4200
HTTP_PORT=8080

cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop http-encoder-test 2>/dev/null || true
    docker rm http-encoder-test 2>/dev/null || true
    pkill -f "VLC.*udp" 2>/dev/null || true
}
trap cleanup EXIT INT

HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "192.168.1.1")
echo "Host IP: $HOST_IP"
echo ""

echo "[1/3] Preparing Big Buck Bunny video..."
if [ ! -f /tmp/big_buck_bunny_720p.mp4 ] || [ $(stat -f%z /tmp/big_buck_bunny_720p.mp4 2>/dev/null || echo 0) -lt 1000000 ]; then
    echo "   Downloading (150MB, ~10 seconds)..."
    curl -L -o /tmp/big_buck_bunny_720p.mp4 "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
    echo "   ✓ Downloaded"
else
    echo "   ✓ Already cached"
fi
echo ""

echo "[2/3] Opening VLC for playback..."
/Applications/VLC.app/Contents/MacOS/VLC "udp://@:${VLC_PORT}" > /dev/null 2>&1 &
sleep 3
echo "   ✓ VLC ready on port ${VLC_PORT}"
echo ""

echo "[3/3] Starting Docker with HTTP Control enabled..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📺  WATCH VLC - Video quality will change dynamically"
echo "  🌐  HTTP API - Listening on port ${HTTP_PORT}"
echo ""
echo "  This test will:"
echo "  1. Start encoding at 10 Mbps"
echo "  2. Apply netem: 5 Mbps bandwidth"
echo "  3. Send HTTP command: 3 Mbps (expect frame skip + bitrate drop)"
echo "  4. Send HTTP command: 15 Mbps (expect recovery)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Build the Docker image if needed
if ! docker images | grep -q ffmpeg-srt-x264tcp; then
    echo "Building Docker image..."
    ./build_x264tcp_image.sh
fi

docker run --rm --name http-encoder-test --cap-add=NET_ADMIN \
    -p ${HTTP_PORT}:${HTTP_PORT} \
    -v /tmp:/tmp \
    ffmpeg-srt-x264tcp \
    bash -c "
set -e

# Start receiver: SRT → UDP to VLC
echo \"Starting receiver (SRT → UDP to VLC)...\"
ffmpeg -hide_banner -loglevel error \
    -protocol_whitelist file,udp,srt \
    -i \"srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=3000&rcvbuf=10000000&sndbuf=10000000\" \
    -c copy \
    -f mpegts \"udp://${HOST_IP}:${VLC_PORT}?pkt_size=1316\" &
RX_PID=\$!
sleep 3

# Start encoder with HTTP control
echo \"Starting encoder with HTTP control...\"
ffmpeg -hide_banner -loglevel info \
    -re -stream_loop -1 -i /tmp/big_buck_bunny_720p.mp4 \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -b:v 10000k \
    -g 60 -sc_threshold 0 \
    -http_control_enable 1 -http_control_port ${HTTP_PORT} \
    -protocol_whitelist file,udp,srt \
    -f mpegts \"srt://127.0.0.1:${SRT_PORT}?mode=caller&latency=3000&sndbuf=10000000\" &
ENCODER_PID=\$!

echo \"\"
echo \"═══════════════════════════════════════════\"
echo \"  ✓ Encoder started with HTTP control\"
echo \"  ✓ HTTP API: http://localhost:${HTTP_PORT}\"
echo \"═══════════════════════════════════════════\"
echo \"\"

# Wait for encoder to stabilize
sleep 15
echo \"[Test Phase 1] Baseline: 10 Mbps encoding\"
echo \"\"

# Apply netem to simulate 5 Mbps network
sleep 10
echo \"\"
echo \"[Test Phase 2] Applying netem: 5 Mbps bandwidth limit\"
tc qdisc del dev lo root 2>/dev/null || true
tc qdisc add dev lo root handle 1: htb default 10
tc class add dev lo parent 1: classid 1:10 htb rate 5mbit
echo \"   ✓ Network limited to 5 Mbps\"
echo \"\"

# Send HTTP command: reduce to 3 Mbps
sleep 15
echo \"\"
echo \"[Test Phase 3] Sending HTTP command: 3 Mbps (with force IDR)\"
curl -X POST http://localhost:${HTTP_PORT} -H \"Content-Type: application/json\" -d '{\"bitrate\":3000,\"force_idr\":1}' 2>/dev/null
echo \"\"
echo \"   ✓ Command sent. Watch VLC for choppy video (frame skipping)\"
echo \"\"

# Wait to observe the change
sleep 20

# Send HTTP command: increase to 15 Mbps
echo \"\"
echo \"[Test Phase 4] Sending HTTP command: 15 Mbps (recovery)\"
curl -X POST http://localhost:${HTTP_PORT} -H \"Content-Type: application/json\" -d '{\"bitrate\":15000,\"force_idr\":1}' 2>/dev/null
echo \"\"
echo \"   ✓ Command sent. Video should become smooth again\"
echo \"\"

# Wait to observe recovery
sleep 20

echo \"\"
echo \"[Test Complete] Stopping encoder...\"
kill \$ENCODER_PID \$RX_PID 2>/dev/null || true
wait \$ENCODER_PID \$RX_PID 2>/dev/null || true

echo \"\"
echo \"✓ Test finished successfully!\"
" 2>&1 | tee /tmp/http_docker_netem_test.log

echo ""
echo "═══════════════════════════════════════════"
echo "  Test complete!"
echo "  Logs saved to: /tmp/http_docker_netem_test.log"
echo "═══════════════════════════════════════════"

