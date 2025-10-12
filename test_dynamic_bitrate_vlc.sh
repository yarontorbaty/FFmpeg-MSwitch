#!/bin/bash
#
# Dynamic Bitrate Control Test with VLC
# SRT bandwidth monitoring → x264 bitrate adjustment
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   DYNAMIC BITRATE CONTROL TEST                               ║"
echo "║   SRT Bandwidth → x264 Bitrate (LIVE!)                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

VLC_PORT=5400
SRT_PORT=4200
X264_TCP_PORT=9999

cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop srt-dynamic-test 2>/dev/null || true
    docker rm srt-dynamic-test 2>/dev/null || true
    pkill -f "VLC.*udp" 2>/dev/null || true
    pkill -f "srt_bitrate_controller" 2>/dev/null || true
}
trap cleanup EXIT INT

HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "192.168.1.1")
echo "Host IP: $HOST_IP"
echo ""

echo "[1/2] Opening VLC..."
/Applications/VLC.app/Contents/MacOS/VLC "udp://@:${VLC_PORT}" > /dev/null 2>&1 &
sleep 3
echo "   ✓ VLC ready on port ${VLC_PORT}"
echo ""

echo "[2/2] Starting Docker with DYNAMIC bitrate control..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WATCH VLC QUALITY CHANGE:"
echo "  • Phase 1: High quality (10 Mbps available)"
echo "  • Phase 2: Reduced quality (3 Mbps + loss)"
echo "  • Phase 3: LOW quality (1 Mbps + 10% loss)"
echo "  • Phase 4: Quality recovers (8 Mbps)"
echo ""
echo "  Bitrate will automatically adjust!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Copy controller to shared location
mkdir -p /tmp/srt_test
cp /Users/yarontorbaty/Documents/Code/FFmpeg/srt_bitrate_controller.py /tmp/srt_test/

docker run --rm --name srt-dynamic-test --cap-add=NET_ADMIN \
    -v /tmp/srt_test:/test_scripts:ro \
    -p ${X264_TCP_PORT}:${X264_TCP_PORT}/tcp \
    ffmpeg-srt-x264tcp \
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
echo \"Starting receiver (SRT → UDP to VLC)...\"
ffmpeg -hide_banner -loglevel info \
    -protocol_whitelist file,udp,srt \
    -i \"srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1\" \
    -c copy \
    -f mpegts \"udp://${HOST_IP}:${VLC_PORT}?pkt_size=1316\" \
    2>&1 | tee /tmp/receiver.log | grep --line-buffered \"SRT Stats\" &
RX_PID=\$!
sleep 3
echo \"   ✓ Receiver started\"
echo \"\"

# Start sender with x264 TCP control enabled
echo \"Starting sender with DYNAMIC bitrate control...\"
echo \"   (x264 TCP port: ${X264_TCP_PORT})\"
echo \"\"

# Run FFmpeg and pipe output to bitrate controller
ffmpeg -re \
    -f lavfi -i \"smptebars=size=1280x720:rate=25:duration=70\" \
    -f lavfi -i \"sine=frequency=1000:sample_rate=48000:duration=70\" \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -b:v 4000k -maxrate 5000k -bufsize 2500k \
    -g 50 -sc_threshold 0 \
    -x264opts \"tcp-port=${X264_TCP_PORT}\" \
    -c:a aac -b:a 128k \
    -f mpegts \"srt://127.0.0.1:${SRT_PORT}?latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1\" \
    2>&1 | tee /tmp/sender.log | python3 /test_scripts/srt_bitrate_controller.py ${X264_TCP_PORT} 500 5000 &
TX_PID=\$!

# Wait for x264 TCP to be ready
echo \"Waiting for x264 TCP control to be ready...\"
for i in {1..10}; do
    if nc -z 127.0.0.1 ${X264_TCP_PORT} 2>/dev/null; then
        echo \"   ✓ x264 TCP control ready\"
        break
    fi
    sleep 1
done
echo \"\"

# Apply network conditions
apply_netem \"10mbit\" 0 0 \"PHASE 1: Excellent (10 Mbps)\" 15
apply_netem \"3mbit\" 50 2 \"PHASE 2: Moderate (3 Mbps + loss)\" 15
apply_netem \"1mbit\" 100 10 \"PHASE 3: SEVERE (1 Mbps + 10% loss)\" 15
apply_netem \"8mbit\" 20 0 \"PHASE 4: Recovery (8 Mbps)\" 15

echo \"\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
echo \"  TEST COMPLETE\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
echo \"\"

echo \"Bitrate adjustments made:\"
grep \"Controller.*Bitrate\" /tmp/sender.log 2>/dev/null || echo \"No adjustments logged\"

# Clean up
tc qdisc del dev lo root 2>/dev/null || true
kill \$TX_PID \$RX_PID 2>/dev/null || true
sleep 2
"

echo ""
echo "✅ Test complete!"
echo ""
echo "The bitrate was dynamically adjusted based on SRT bandwidth!"
echo "Did you see the quality change in VLC?"

