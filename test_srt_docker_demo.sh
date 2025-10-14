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
DNCTL_PIPE=1
DNCTL_INTERFACE="lo0"  # Loopback interface for local testing

cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop ${CONTAINER_NAME} 2>/dev/null || true
    docker rm ${CONTAINER_NAME} 2>/dev/null || true
    pkill -f "ffplay.*srt" 2>/dev/null || true
    pkill -f "plot_hysteresis.py" 2>/dev/null || true
    
    # Clean up dnctl/pfctl rules
    echo "Removing bandwidth controls..."
    sudo dnctl pipe delete ${DNCTL_PIPE} 2>/dev/null || true
    sudo pfctl -f /etc/pf.conf 2>/dev/null || true
    sudo pfctl -d 2>/dev/null || true
    
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

# Note: ffplay will be started in background after Docker is ready
echo "[2/3] Preparing ffplay receiver..."
FFPLAY_LOG="/tmp/ffplay_receiver.log"
rm -f "$FFPLAY_LOG"

# Start ffplay in background with retry logic
(
    echo "Waiting for SRT listener to be ready..."
    sleep 10  # Wait for Docker container to start and FFmpeg to begin listening
    
    # Try to connect with ffplay
    if [ -n "$SUDO_USER" ]; then
        sudo -u "$SUDO_USER" ffplay -loglevel info -stats "srt://127.0.0.1:${SRT_PORT}?mode=caller&transtype=live&latency=3000" > "$FFPLAY_LOG" 2>&1
    else
        ffplay -loglevel info -stats "srt://127.0.0.1:${SRT_PORT}?mode=caller&transtype=live&latency=3000" > "$FFPLAY_LOG" 2>&1
    fi
) &
FFPLAY_PID=$!
echo "   ✓ ffplay will connect once SRT listener is ready"
echo "   📝 ffplay log: $FFPLAY_LOG"
echo ""

# Start network throughput monitor using Docker stats
echo "[3/4] Starting network throughput monitor..."
THROUGHPUT_LOG="/tmp/network_throughput.log"
rm -f "$THROUGHPUT_LOG"
(
    sleep 5  # Wait for container to start
    echo "# timestamp bytes_total mbps" > "$THROUGHPUT_LOG"
    last_bytes=0
    last_time=0
    
    while true; do
        # Get network TX bytes from Docker container
        stats=$(docker stats ${CONTAINER_NAME} --no-stream --format "{{.NetIO}}" 2>/dev/null)
        if [ -n "$stats" ]; then
            # Extract TX bytes (format: "RX / TX")
            tx_bytes=$(echo "$stats" | awk '{print $3}' | sed 's/[^0-9.]//g')
            tx_unit=$(echo "$stats" | awk '{print $3}' | sed 's/[0-9.]//g')
            
            # Convert to bytes
            case "$tx_unit" in
                kB) tx_bytes=$(echo "$tx_bytes * 1000" | bc) ;;
                MB) tx_bytes=$(echo "$tx_bytes * 1000000" | bc) ;;
                GB) tx_bytes=$(echo "$tx_bytes * 1000000000" | bc) ;;
                B|*) ;;
            esac
            
            current_time=$(date +%s.%N)
            
            # Calculate Mbps if we have previous measurement
            if [ "$last_time" != "0" ]; then
                time_delta=$(echo "$current_time - $last_time" | bc)
                bytes_delta=$(echo "$tx_bytes - $last_bytes" | bc)
                if (( $(echo "$time_delta > 0" | bc -l) )); then
                    mbps=$(echo "scale=3; ($bytes_delta * 8) / ($time_delta * 1000000)" | bc)
                    echo "$current_time $tx_bytes $mbps" >> "$THROUGHPUT_LOG"
                fi
            fi
            
            last_bytes=$tx_bytes
            last_time=$current_time
        fi
        
        sleep 0.5
    done
) &
NETMON_PID=$!
echo "   ✓ Network monitor started (PID: $NETMON_PID)"
echo "   📊 Throughput log: $THROUGHPUT_LOG"
echo ""

# Start plotting (as regular user even when sudo is used)
echo "[4/4] Starting real-time plot..."
rm -f /tmp/sender.log  # Clear old logs
if [ -n "$SUDO_USER" ]; then
    # Running with sudo, so launch plot as the original user
    sudo -u "$SUDO_USER" python3 plot_hysteresis.py &
    PLOT_PID=$!
else
    # Not running with sudo, launch normally
    python3 plot_hysteresis.py &
    PLOT_PID=$!
fi
sleep 2
echo "   ✓ Plot started (PID: $PLOT_PID)"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📺  WATCH ffplay - Direct SRT connection to Docker"
echo "  📊  GRAPH - Real-time bitrate + packet loss plot"
echo ""
echo "  🎛️  AUTOMATED BANDWIDTH CONTROL:"
echo "     Phase 1 (0-20s):  Unlimited (25 Mbps encoding)"
echo "     Phase 2 (20-40s): 15 Mbps"
echo "     Phase 3 (40-60s): 5 Mbps"
echo "     Phase 4 (60s+):   Unlimited"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Start automated bandwidth control in background
(
    echo "🎛️  Starting automated bandwidth control..."
    
    # Phase 1: Unlimited - Encoding at 25 Mbps (0-20s)
    echo "[0s] Phase 1: Unlimited bandwidth (encoding at 25 Mbps)"
    sudo dnctl pipe delete ${DNCTL_PIPE} 2>/dev/null || true
    sudo pfctl -d 2>/dev/null || true
    sleep 20
    
    # Phase 2: 15 Mbps (20-40s)
    echo "[20s] Phase 2: Limiting to 15 Mbps"
    sudo dnctl pipe ${DNCTL_PIPE} config bw 15Mbit/s
    sudo pfctl -f - <<EOF
dummynet out proto udp from any to any port ${SRT_PORT} pipe ${DNCTL_PIPE}
dummynet in proto udp from any port ${SRT_PORT} to any pipe ${DNCTL_PIPE}
EOF
    sudo pfctl -e 2>/dev/null || true
    sleep 20
    
    # Phase 3: 5 Mbps (40-60s)
    echo "[40s] Phase 3: Reducing to 5 Mbps"
    sudo dnctl pipe ${DNCTL_PIPE} config bw 5Mbit/s
    sleep 20
    
    # Phase 4: Unlimited (60s+)
    echo "[60s] Phase 4: Removing bandwidth limit"
    sudo dnctl pipe delete ${DNCTL_PIPE} 2>/dev/null || true
    sudo pfctl -d 2>/dev/null || true
    echo "Test phases complete!"
) &
BW_CONTROL_PID=$!
echo "✓ Bandwidth controller started (PID: $BW_CONTROL_PID)"
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
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=32:fontcolor=yellow:box=1:boxcolor=green@0.85:boxborderw=10:x=30:y=100:text='PHASE 1\\: Unlimited - 25 Mbps (0-20s)':enable='between(t,0,20)',
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=32:fontcolor=yellow:box=1:boxcolor=orange@0.85:boxborderw=10:x=30:y=100:text='PHASE 2\\: 15 Mbps (20-40s)':enable='between(t,20,40)',
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=32:fontcolor=yellow:box=1:boxcolor=red@0.85:boxborderw=10:x=30:y=100:text='PHASE 3\\: 5 Mbps (40-60s)':enable='between(t,40,60)',
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=32:fontcolor=yellow:box=1:boxcolor=green@0.85:boxborderw=10:x=30:y=100:text='PHASE 4\\: Unlimited (60s+)':enable='gte(t,60)',
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=28:fontcolor=white:box=1:boxcolor=blue@0.75:boxborderw=8:x=30:y=160:text='Threshold\\: 30 pct | Upshift Delay\\: 5s | Buffer Canary\\: ON'\" \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -b:v 250000k \
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
echo \"   ✓ FFmpeg sender started (SRT listener ready on port ${SRT_PORT})\"
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

