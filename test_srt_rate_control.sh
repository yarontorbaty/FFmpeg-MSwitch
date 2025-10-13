#!/bin/bash
#
# Test SRT Rate Control - Built-in Dynamic Bitrate Adjustment
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   SRT RATE CONTROL TEST                                      ║"
echo "║   Built-in Dynamic Bitrate Adjustment                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

VLC_PORT=5400
SRT_PORT=4200

cleanup() {
    echo ""
    echo "Cleaning up..."
    docker stop srt-rate-control-test 2>/dev/null || true
    docker rm srt-rate-control-test 2>/dev/null || true
    pkill -f "VLC.*udp" 2>/dev/null || true
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

echo "[2/3] Preparing Big Buck Bunny video..."
if [ ! -f /tmp/big_buck_bunny_720p.mp4 ] || [ $(stat -f%z /tmp/big_buck_bunny_720p.mp4 2>/dev/null || echo 0) -lt 1000000 ]; then
    echo "   Downloading (150MB, ~10 seconds)..."
    curl -L -o /tmp/big_buck_bunny_720p.mp4 "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
    echo "   ✓ Downloaded"
else
    echo "   ✓ Already cached"
fi
echo ""

echo "[3/3] Starting Docker with SRT Rate Control..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WATCH VLC - Quality will change automatically:"
echo "  • Phase 1: High quality (10 Mbps available)"
echo "  • Phase 2: Reduced quality (3 Mbps + loss)"
echo "  • Phase 3: LOW quality (1 Mbps + 10% loss)"
echo "  • Phase 4: Quality recovers (8 Mbps)"
echo ""
echo "  libx264 will adjust bitrate based on SRT stats!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

docker run --rm --name srt-rate-control-test --cap-add=NET_ADMIN \
    -v /tmp:/tmp \
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

# Start receiver: SRT → UDP to VLC
echo \"Starting receiver (SRT → UDP to VLC)...\"
ffmpeg -hide_banner -loglevel info \
    -protocol_whitelist file,udp,srt \
    -i \"srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=3000&rcvbuf=10000000&sndbuf=10000000&enable_stats=1\" \
    -c copy \
    -f mpegts \"udp://${HOST_IP}:${VLC_PORT}?pkt_size=1316\" \
    2>&1 | tee /tmp/receiver.log | grep --line-buffered \"SRT Stats\" &
RX_PID=\$!
sleep 3
echo \"   ✓ Receiver started\"
echo \"\"

# Start sender with built-in SRT rate control (using Big Buck Bunny)
echo \"Starting sender with SRT Rate Control...\"
echo \"   (Min: 500 kbps, Max: 5000 kbps)\"
echo \"\"

ffmpeg -re -stream_loop -1 \
    -i /tmp/big_buck_bunny_720p.mp4 \
    -vf \"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:fontsize=32:fontcolor=white:box=1:boxcolor=black@0.7:boxborderw=10:x=20:y=20:text='SRT Rate Control Demo':enable=1,
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=green@0.8:boxborderw=8:x=20:y=80:text='PHASE 1 | Network\\: Excellent (10 Mbps) | Target\\: 5 Mbps':enable='between(t,0,25)',
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=orange@0.8:boxborderw=8:x=20:y=80:text='PHASE 2 | Network\\: Moderate (3 Mbps + 2pct loss) | Target\\: ~1.5 Mbps':enable='between(t,25,50)',
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=red@0.8:boxborderw=8:x=20:y=80:text='PHASE 3 | Network\\: SEVERE (1 Mbps + 10pct loss) | Target\\: 0.5 Mbps':enable='between(t,50,75)',
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=blue@0.8:boxborderw=8:x=20:y=80:text='PHASE 4 | Network\\: Recovery (8 Mbps) | Target\\: ~4 Mbps':enable='gte(t,75)'\" \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -g 50 -sc_threshold 0 \
    -srt_rate_control 1 \
    -srt_min_bitrate 500000 \
    -srt_max_bitrate 5000000 \
    -c:a aac -b:a 128k \
    -f mpegts \"srt://127.0.0.1:${SRT_PORT}?latency=3000&rcvbuf=10000000&sndbuf=10000000&enable_stats=1\" \
    2>&1 | tee /tmp/sender.log &
TX_PID=\$!

sleep 3
echo \"   ✓ FFmpeg sender started\"
echo \"\"
echo \"Look for '[SRT Rate Control]' messages in the logs...\"
echo \"\"

# Apply network conditions
apply_netem \"10mbit\" 0 0 \"PHASE 1: Excellent (10 Mbps)\" 25
apply_netem \"3mbit\" 50 2 \"PHASE 2: Moderate (3 Mbps + loss)\" 25
apply_netem \"1mbit\" 100 10 \"PHASE 3: SEVERE (1 Mbps + 10% loss)\" 25
apply_netem \"8mbit\" 20 0 \"PHASE 4: Recovery (8 Mbps)\" 25

echo \"\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
echo \"  TEST COMPLETE\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
echo \"\"

echo \"Bitrate adjustments made:\"
grep \"SRT Rate Control\" /tmp/sender.log 2>/dev/null || echo \"No adjustments logged\"
echo \"\"

echo \"SRT Stats observed:\"
grep \"SRT Stats\" /tmp/receiver.log 2>/dev/null | tail -10 || echo \"No stats logged\"

# Clean up
tc qdisc del dev lo root 2>/dev/null || true
kill \$TX_PID \$RX_PID 2>/dev/null || true
sleep 2
"

echo ""
echo "Done! Check VLC for visual quality changes."
echo ""

