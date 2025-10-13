#!/bin/bash
#
# Netem + VLC Visual Test
# Stream from Docker (with netem) to VLC on macOS
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   SRT + Netem + VLC Visual Test                              ║"
echo "║   You will SEE network degradation in VLC!                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

VLC_PORT=5555
SRT_PORT=4200

cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop srt-netem-vlc 2>/dev/null || true
    pkill -f "VLC.*udp://@:${VLC_PORT}" 2>/dev/null || true
}
trap cleanup EXIT INT

echo "[1/2] Opening VLC player..."
/Applications/VLC.app/Contents/MacOS/VLC "udp://@:${VLC_PORT}" > /dev/null 2>&1 &
sleep 3
echo "   ✓ VLC opened on port ${VLC_PORT}"
echo ""

echo "[2/2] Starting Docker with netem simulation..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Watch VLC! You should see:"
echo "  • Phase 1 (20s): Smooth playback at 10 Mbps"
echo "  • Phase 2 (20s): Slight degradation at 3 Mbps + 2% loss"
echo "  • Phase 3 (20s): SEVERE artifacts at 1 Mbps + 10% loss"
echo "  • Phase 4 (20s): Recovery at 8 Mbps"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

docker run --rm --name srt-netem-vlc --cap-add=NET_ADMIN \
    --network host \
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
    echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
    echo \"  \$label\"
    echo \"  Rate: \$rate | Delay: \${delay}ms | Loss: \$loss%\"
    echo \"  Duration: \${duration}s\"
    echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
    
    # Clear old rules
    tc qdisc del dev lo root 2>/dev/null || true
    
    # Add HTB + class + netem (based on your libsrt approach)
    tc qdisc add dev lo root handle 1: htb default 10
    tc class add dev lo parent 1: classid 1:10 htb rate \${rate}
    
    if [ \"\$delay\" != \"0\" ] || [ \"\$loss\" != \"0\" ]; then
        local netem_opts=\"\"
        [ \"\$delay\" != \"0\" ] && netem_opts=\"delay \${delay}ms\"
        [ \"\$loss\" != \"0\" ] && netem_opts=\"\$netem_opts loss \${loss}%\"
        tc qdisc add dev lo parent 1:10 handle 10: netem \$netem_opts
    fi
    
    # Show active rules
    tc qdisc show dev lo | head -3
    echo \"\"
    
    sleep \$duration
}

echo \"Starting SRT receiver (internal)...\"
ffmpeg -hide_banner -loglevel info \
    -protocol_whitelist file,udp,srt \
    -i \"srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1\" \
    -c copy -f mpegts \"udp://127.0.0.1:${VLC_PORT}?pkt_size=1316\" \
    > /tmp/receiver.log 2>&1 &
RX_PID=\$!
sleep 3
echo \"   ✓ Receiver started, forwarding to VLC\"
echo \"\"

echo \"Starting SRT sender (internal)...\"
ffmpeg -re \
    -f lavfi -i \"smptebars=size=1280x720:rate=25:duration=90\" \
    -f lavfi -i \"sine=frequency=1000:sample_rate=48000:duration=90\" \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -b:v 3M -maxrate 3M -bufsize 1.5M \
    -g 50 -sc_threshold 0 \
    -c:a aac -b:a 128k \
    -f mpegts \"srt://127.0.0.1:${SRT_PORT}?latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1\" \
    2>&1 | grep --line-buffered -E \"SRT Stats|frame=\" &
TX_PID=\$!
sleep 5
echo \"   ✓ Sender started (3 Mbps target)\"
echo \"\"

# Apply network conditions
apply_netem \"10mbit\" 0 0 \"PHASE 1: Excellent (10 Mbps, 0ms, 0% loss)\" 20
apply_netem \"3mbit\" 50 2 \"PHASE 2: Moderate (3 Mbps, 50ms, 2% loss)\" 20
apply_netem \"1mbit\" 100 10 \"PHASE 3: SEVERE (1 Mbps, 100ms, 10% loss)\" 20
apply_netem \"8mbit\" 20 0 \"PHASE 4: Recovery (8 Mbps, 20ms, 0% loss)\" 20

echo \"\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
echo \"  TEST COMPLETE\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
echo \"\"

echo \"Receiver log (last 30 lines):\"
tail -30 /tmp/receiver.log 2>/dev/null | grep -E \"SRT Stats|frame=\" || echo \"No stats found\"

# Clean up
tc qdisc del dev lo root 2>/dev/null || true
kill \$TX_PID \$RX_PID 2>/dev/null || true
sleep 2
"

echo ""
echo "✅ Test finished!"
echo ""
echo "Did you see the network impact in VLC?"
echo "  Phase 1: Smooth playback"
echo "  Phase 2: Minor buffering"
echo "  Phase 3: SEVERE buffering/stuttering/artifacts"
echo "  Phase 4: Recovery"

