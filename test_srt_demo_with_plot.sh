#!/bin/bash
#
# SRT Rate Control Demo with Real-Time Bitrate Plot
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   SRT RATE CONTROL DEMO (with Real-Time Plot)               ║"
echo "║   Dynamic Bitrate Adjustment + Visual Overlay                ║"
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
    pkill -f "plot_bitrate.py" 2>/dev/null || true
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

echo "[3/3] Starting Docker with SRT Rate Control + Real-Time Plot..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📺  WATCH VLC - On-screen overlay shows network phase"
echo "  📊  GRAPH - Real-time bitrate plot will appear"
echo ""
echo "  Phase 1 (0-25s):  Excellent | 30 Mbps → Target: 20 Mbps"
echo "  Phase 2 (25-50s): Moderate  | 15 Mbps + loss → ~10 Mbps"
echo "  Phase 3 (50-75s): REDUCED   | 8 Mbps + loss → ~5 Mbps"  
echo "  Phase 4 (75-100s): Recovery  | 30 Mbps → ~20 Mbps"
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
    2>&1 | grep --line-buffered \"SRT Stats\" &
RX_PID=\$!
sleep 3
echo \"   ✓ Receiver started\"
echo \"\"

# Start sender with SRT rate control and overlay
echo \"Starting sender with SRT Rate Control + Overlay...\"
echo \"   (Min: 500 kbps, Max: 5000 kbps)\"
echo \"\"

ffmpeg -re -stream_loop -1 \
    -i /tmp/big_buck_bunny_720p.mp4 \
    -vf \"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:fontsize=32:fontcolor=white:box=1:boxcolor=black@0.7:boxborderw=10:x=20:y=20:text='SRT Rate Control Demo':enable=1,
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=green@0.8:boxborderw=8:x=20:y=80:text='PHASE 1 | Network\\: Excellent (30 Mbps) | Target\\: 20 Mbps':enable='between(t,0,25)',
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=orange@0.8:boxborderw=8:x=20:y=80:text='PHASE 2 | Network\\: Moderate (15 Mbps + 2pct loss) | Target\\: ~10 Mbps':enable='between(t,25,50)',
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=red@0.8:boxborderw=8:x=20:y=80:text='PHASE 3 | Network\\: REDUCED (8 Mbps + 5pct loss) | Target\\: ~5 Mbps':enable='between(t,50,75)',
         drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=blue@0.8:boxborderw=8:x=20:y=80:text='PHASE 4 | Network\\: Recovery (30 Mbps) | Target\\: ~20 Mbps':enable='gte(t,75)'\" \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -b:v 20000k \
    -g 50 -sc_threshold 0 \
    -srt_rate_control 1 \
    -srt_min_bitrate 5000000 \
    -srt_max_bitrate 25000000 \
    -c:a aac -b:a 128k \
    -f mpegts \"srt://127.0.0.1:${SRT_PORT}?latency=3000&rcvbuf=10000000&sndbuf=10000000&enable_stats=1\" \
    2>&1 | tee /tmp/sender.log &
TX_PID=\$!

sleep 3
echo \"   ✓ FFmpeg sender started\"
echo \"\"
echo \"Look for '[SRT Rate Control]' messages below...\"
echo \"\"

# Apply network conditions
apply_netem \"30mbit\" 0 0 \"PHASE 1: Excellent (30 Mbps)\" 25
apply_netem \"15mbit\" 50 2 \"PHASE 2: Moderate (15 Mbps + 2% loss)\" 25
apply_netem \"8mbit\" 100 5 \"PHASE 3: REDUCED (8 Mbps + 5% loss)\" 25
apply_netem \"30mbit\" 20 0 \"PHASE 4: Recovery (30 Mbps)\" 25

echo \"\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
echo \"  TEST COMPLETE\"
echo \"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\"
echo \"\"

echo \"Bitrate adjustments made:\"
grep \"SRT Rate Control\" /tmp/sender.log 2>/dev/null | tail -20 || echo \"No adjustments logged\"

# Clean up
tc qdisc del dev lo root 2>/dev/null || true
kill \$TX_PID \$RX_PID 2>/dev/null || true
sleep 2
" 2>&1 | python3 /Users/yarontorbaty/Documents/Code/FFmpeg/plot_bitrate.py

echo ""
echo "Done! Demo complete."
echo ""

