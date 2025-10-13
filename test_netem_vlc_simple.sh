#!/bin/bash
#
# Netem + VLC Simple Test
# Simpler approach: multicast directly to host
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   SRT + Netem + VLC Visual Test                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

VLC_PORT=5400
SRT_PORT=4200

cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop srt-vlc-test 2>/dev/null || true
    docker rm srt-vlc-test 2>/dev/null || true
    pkill -f "VLC.*udp" 2>/dev/null || true
}
trap cleanup EXIT INT

# Get host IP for Docker to reach back
HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "192.168.1.1")
echo "Host IP: $HOST_IP"
echo ""

echo "[1/2] Opening VLC on UDP port ${VLC_PORT}..."
/Applications/VLC.app/Contents/MacOS/VLC "udp://@:${VLC_PORT}" > /dev/null 2>&1 &
sleep 3
echo "   ✓ VLC ready"
echo ""

echo "[2/2] Starting Docker test (will stream to VLC)..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WATCH VLC - You will see network impact:"
echo "  • Phase 1 (15s): Smooth @ 10 Mbps"
echo "  • Phase 2 (15s): Degradation @ 3 Mbps + loss"
echo "  • Phase 3 (15s): SEVERE @ 1 Mbps + 10% loss"
echo "  • Phase 4 (15s): Recovery @ 8 Mbps"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

docker run --rm --name srt-vlc-test --cap-add=NET_ADMIN \
    ffmpeg-enhanced-srt \
    bash -c "
set -e

apply_netem() {
    local rate=\$1
    local delay=\$2
    local loss=\$3
    local label=\$4
    local duration=\$5
    
    echo \"\"
    echo \"[\$(date +%H:%M:%S)] \$label\"
    echo \"  → BW: \$rate, Delay: \${delay}ms, Loss: \$loss%\"
    
    tc qdisc del dev lo root 2>/dev/null || true
    tc qdisc add dev lo root handle 1: htb default 10
    tc class add dev lo parent 1: classid 1:10 htb rate \${rate}
    
    if [ \"\$delay\" != \"0\" ] || [ \"\$loss\" != \"0\" ]; then
        local netem_opts=\"\"
        [ \"\$delay\" != \"0\" ] && netem_opts=\"delay \${delay}ms\"
        [ \"\$loss\" != \"0\" ] && netem_opts=\"\$netem_opts loss \${loss}%\"
        tc qdisc add dev lo parent 1:10 handle 10: netem \$netem_opts
    fi
    
    sleep \$duration
}

# Start receiver: SRT → UDP to host
echo \"Starting receiver (forwarding to ${HOST_IP}:${VLC_PORT})...\"
ffmpeg -hide_banner -loglevel info \
    -protocol_whitelist file,udp,srt \
    -i \"srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1\" \
    -c copy \
    -f mpegts \"udp://${HOST_IP}:${VLC_PORT}?pkt_size=1316\" \
    2>&1 | grep --line-buffered \"SRT Stats\" &
RX_PID=\$!
sleep 3

# Start sender: encode → SRT (loopback with netem)
echo \"Starting sender (encoding at 3 Mbps CBR)...\"
ffmpeg -re \
    -f lavfi -i \"smptebars=size=1280x720:rate=25:duration=70\" \
    -f lavfi -i \"sine=frequency=1000:sample_rate=48000:duration=70\" \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -b:v 3M -maxrate 3M -bufsize 1.5M -g 50 -sc_threshold 0 \
    -c:a aac -b:a 128k \
    -f mpegts \"srt://127.0.0.1:${SRT_PORT}?latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1\" \
    2>&1 | grep --line-buffered -E \"SRT Stats|frame=\" &
TX_PID=\$!
sleep 5

apply_netem \"10mbit\" 0 0 \"PHASE 1: Excellent\" 15
apply_netem \"3mbit\" 50 2 \"PHASE 2: Moderate\" 15
apply_netem \"1mbit\" 100 10 \"PHASE 3: SEVERE\" 15
apply_netem \"8mbit\" 20 0 \"PHASE 4: Recovery\" 15

echo \"\"
echo \"Test complete. Stopping...\"
tc qdisc del dev lo root 2>/dev/null || true
kill \$TX_PID \$RX_PID 2>/dev/null || true
"

echo ""
echo "✅ Done! Check VLC - did you see the degradation?"

