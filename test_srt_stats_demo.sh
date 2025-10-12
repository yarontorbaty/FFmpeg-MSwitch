#!/bin/bash
#
# SRT Stats Demo - Show what stats we're getting
# This demonstrates the foundation for rate control
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   SRT Network Stats Monitoring Demo                         ║"
echo "║   Foundation for Dynamic Bitrate Control                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

VLC_PORT=5400
SRT_PORT=4200

cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop srt-stats-demo 2>/dev/null || true
    pkill -f "VLC.*5400" 2>/dev/null || true
}
trap cleanup EXIT INT

HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "192.168.1.1")

echo "[1/2] Opening VLC on port ${VLC_PORT}..."
/Applications/VLC.app/Contents/MacOS/VLC "udp://@:${VLC_PORT}" > /dev/null 2>&1 &
sleep 3
echo "   ✓ VLC ready"
echo ""

echo "[2/2] Starting SRT stream with network monitoring..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Watch the SRT Stats change with network conditions!"
echo "  This data is used for bitrate control decisions."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

docker run --rm --name srt-stats-demo --cap-add=NET_ADMIN \
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
    echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
    echo \"  \$label\"
    echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
    
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

# Start receiver
echo \"Starting receiver (SRT → UDP to VLC)...\"
ffmpeg -hide_banner -loglevel info \
    -protocol_whitelist file,udp,srt \
    -i \"srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1\" \
    -c copy \
    -f mpegts \"udp://${HOST_IP}:${VLC_PORT}?pkt_size=1316\" \
    2>&1 | grep --line-buffered \"SRT Stats\" &
RX_PID=\$!
sleep 3

# Start sender
echo \"Starting sender (encoding at 3 Mbps)...\"
echo \"\"
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

apply_netem \"10mbit\" 0 0 \"PHASE 1: Excellent (10 Mbps) - BW should be ~10-12 Mbps\" 15
apply_netem \"3mbit\" 50 2 \"PHASE 2: Moderate (3 Mbps + loss) - BW drops to ~2-3 Mbps, loss appears\" 15
apply_netem \"1mbit\" 100 10 \"PHASE 3: SEVERE (1 Mbps + 10% loss) - BW ~0.6-1 Mbps, high loss\" 15
apply_netem \"8mbit\" 20 0 \"PHASE 4: Recovery (8 Mbps) - BW climbs back to 4-8 Mbps\" 15

echo \"\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
echo \"  COMPLETE - Stats show network-aware monitoring works!\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"

tc qdisc del dev lo root 2>/dev/null || true
kill \$TX_PID \$RX_PID 2>/dev/null || true
"

echo ""
echo "✅ Demo complete!"
echo ""
echo "NEXT STEPS for Dynamic Bitrate Control:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "To implement real-time bitrate changes in libx264/libx265,"
echo "we need to either:"
echo ""
echo "  1. Use x264_encoder_reconfig() API directly in libx264.c"
echo "     → Modify libx264.c to check SRT stats and call reconfig"
echo ""
echo "  2. Use segment encoding with bitrate changes between segments"
echo "     → Encode in 5-second chunks, adjust bitrate between chunks"
echo ""
echo "  3. Use the srt_rate_control module we built"
echo "     → Need to integrate it into the encoder init/encode functions"
echo ""
echo "Which approach would you like to implement?"

