#!/bin/bash
#
# SRT Smart Hysteresis Demo - Docker (manual bandwidth control)
# Direct SRT: FFmpeg sender (Docker) → SRT → VLC (Host)
# Use dnctl/pfctl on host to control bandwidth manually
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   SRT SMART HYSTERESIS + BUFFER CANARY (Docker)              ║"
echo "║   Features: Fast Detection | Smart Thresholds | Rate Limit  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

SRT_PORT=4200
IMAGE_NAME="ffmpeg-srt-x264tcp"
CONTAINER_NAME="srt-hysteresis-demo"
UPSHIFT_DELAY_MS=5000
CHANGE_THRESHOLD=30  # Minimum 30% bandwidth change to trigger adjustment

cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop ${CONTAINER_NAME} 2>/dev/null || true
    docker rm ${CONTAINER_NAME} 2>/dev/null || true
    pkill -f "VLC.*srt" 2>/dev/null || true
    pkill -f "plot_hysteresis.py" 2>/dev/null || true
    echo "✓ Cleanup complete"
}
trap cleanup EXIT INT

# Prepare video
echo "[1/3] Preparing Big Buck Bunny video..."
if [ ! -f /tmp/big_buck_bunny_720p.mp4 ] || [ $(stat -f%z /tmp/big_buck_bunny_720p.mp4 2>/dev/null || echo 0) -lt 1000000 ]; then
    echo "   Downloading..."
    curl -L -o /tmp/big_buck_bunny_720p.mp4 "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
    echo "   ✓ Downloaded"
else
    echo "   ✓ Already cached"
fi
echo ""

# Start VLC with direct SRT connection
echo "[2/3] Opening VLC for SRT playback..."
/Applications/VLC.app/Contents/MacOS/VLC "srt://127.0.0.1:${SRT_PORT}?mode=caller&transtype=live&latency=3000" > /dev/null 2>&1 &
sleep 3
echo "   ✓ VLC ready for SRT on port ${SRT_PORT}"
echo ""

# Start plotting
echo "[3/3] Starting real-time plot..."
osascript -e 'tell application "Terminal" to do script "cd '"$(pwd)"' && python3 plot_hysteresis.py"' &
sleep 2
echo "   ✓ Plot window opened"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📺  WATCH VLC - Direct SRT connection to Docker"
echo "  📊  GRAPH - Real-time bitrate + packet loss plot"
echo ""
echo "  💡 MANUAL BANDWIDTH CONTROL:"
echo "     Use dnctl/pfctl on macOS to control bandwidth"
echo ""
echo "  Suggested test phases:"
echo "    Phase 1: No limit (baseline)"
echo "    Phase 2: sudo dnctl pipe 1 config bw 8Mbit/s delay 100ms plr 0.03"
echo "    Phase 3: sudo dnctl pipe 1 config bw 15Mbit/s delay 50ms plr 0.01"
echo "    Phase 4: sudo dnctl pipe 1 config bw 6Mbit/s delay 100ms plr 0.02"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

docker run --rm --name ${CONTAINER_NAME} \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    -v /tmp:/tmp \
    ${IMAGE_NAME} \
    bash -c "
set -e

# Start FFmpeg sender with SRT smart hysteresis and overlay
echo \"Starting FFmpeg sender with SRT Smart Hysteresis + Buffer Canary...\"
echo \"   Min: 3 Mbps, Max: 25 Mbps\"
echo \"   Change threshold: ${CHANGE_THRESHOLD}% (ignore smaller changes)\"
echo \"   Upshift delay: ${UPSHIFT_DELAY_MS}ms\"
echo \"   Buffer canary: Enabled (instant detection <1s)\"
echo \"\"

ffmpeg -re -stream_loop -1 \
    -i /tmp/big_buck_bunny_720p.mp4 \
    -vf \"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:fontsize=40:fontcolor=white:box=1:boxcolor=black@0.8:boxborderw=12:x=30:y=30:text='SRT Smart Hysteresis Demo':enable=1,
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=28:fontcolor=white:box=1:boxcolor=cyan@0.85:boxborderw=10:x=30:y=100:text='Use dnctl to control bandwidth manually':enable=1\" \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -b:v 10000k \
    -g 60 \
    -srt_rate_control 1 \
    -srt_disable_auto_adjust 0 \
    -enable_encoder_restart 1 \
    -srt_min_bitrate 3000000 \
    -srt_max_bitrate 25000000 \
    -srt_latency 3000 \
    -srt_bitrate_change_threshold 30 \
    -srt_upshift_delay_ms ${UPSHIFT_DELAY_MS} \
    -c:a aac -b:a 128k \
    -f mpegts \"srt://0.0.0.0:${SRT_PORT}?mode=listener&transtype=live&latency=3000&rcvbuf=10000000&sndbuf=10000000&enable_stats=1\" \
    2>&1 | tee /tmp/sender.log &
TX_PID=\$!

sleep 5
echo \"   ✓ FFmpeg sender started\"
echo \"\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
echo \"  Look for these log messages:\"
echo \"    • [SRT Stats] - Network bandwidth measurements\"
echo \"    • [SRT Rate Control] - Bitrate decisions\"
echo \"    • [Encoder restart] - Instant bitrate changes\"
echo \"    • [⏸️  rate-limited] - Restart throttling (max 1 per 5s)\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
echo \"\"
echo \"💡 Monitor logs with:\"
echo \"   tail -f /tmp/sender.log | grep --color=always 'SRT Rate Control\\|Encoder restart'\"
echo \"\"
echo \"Press Ctrl+C to stop the test\"
echo \"\"

# Wait for user to stop
tail -f /tmp/sender.log 2>/dev/null || sleep infinity
"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    DEMO COMPLETE!                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

