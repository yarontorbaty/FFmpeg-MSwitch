#!/bin/bash
#
# Aggressive CBR Test - Based on libsrt netem approach
# Small buffers + severe network conditions = visible impact
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Aggressive SRT Test - Small Buffers + Severe Network      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

SRT_PORT=4200
UDP_PORT=5000

cleanup() {
    echo "Cleaning up..."
    docker stop srt-aggressive 2>/dev/null || true
    pkill -f "ffmpeg.*${SRT_PORT}" 2>/dev/null || true
}
trap cleanup EXIT INT

# Start Docker with aggressive netem
echo "Starting receiver with aggressive network simulation..."
echo ""

docker run -d --name srt-aggressive --cap-add=NET_ADMIN \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    srt-navrc-test \
    bash -c '
        apply_netem() {
            local rate=$1
            local delay=$2
            local loss=$3
            local label=$4
            
            tc qdisc del dev eth0 root 2>/dev/null || true
            tc qdisc add dev eth0 root handle 1: htb default 10
            tc class add dev eth0 parent 1: classid 1:10 htb rate ${rate}
            
            # Add netem for delay and loss if specified
            if [ "$delay" != "0" ] || [ "$loss" != "0" ]; then
                local netem_opts=""
                [ "$delay" != "0" ] && netem_opts="delay ${delay}ms"
                [ "$loss" != "0" ] && netem_opts="$netem_opts loss ${loss}%"
                tc qdisc add dev eth0 parent 1:10 handle 10: netem $netem_opts
            fi
            
            echo "[$(date +%H:%M:%S)] $label"
            echo "   Rate: $rate, Delay: ${delay}ms, Loss: $loss%"
            tc qdisc show dev eth0 | head -3
        }
        
        # Start receiver with SMALL buffers
        ffmpeg -hide_banner -v info \
            -protocol_whitelist file,udp,srt \
            -i "srt://0.0.0.0:4200?mode=listener&latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1" \
            -c copy -f null - 2>&1 | grep --line-buffered "SRT Stats" &
        
        sleep 8
        
        apply_netem "10mbit" 0 0 "Phase 1: Excellent (10 Mbps)"
        sleep 25
        
        apply_netem "3mbit" 50 2 "Phase 2: Moderate (3 Mbps + 50ms + 2% loss)"
        sleep 25
        
        apply_netem "1mbit" 100 10 "Phase 3: SEVERE (1 Mbps + 100ms + 10% loss)"
        sleep 25
        
        apply_netem "8mbit" 20 0 "Phase 4: Recovery (8 Mbps + 20ms)"
        sleep 25
        
        echo "Complete"
        wait
    '

sleep 5
echo "✓ Receiver ready with SMALL buffers (100ms latency)"
echo ""

# Open VLC
echo "Opening VLC..."
/Applications/VLC.app/Contents/MacOS/VLC udp://@:${UDP_PORT} > /dev/null 2>&1 &
sleep 2
echo "✓ VLC opened"
echo ""

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              Starting CBR Stream (5 Mbps)                    ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  SMALL SRT BUFFERS (100ms) - Changes will be VISIBLE!       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

cd /Users/yarontorbaty/Documents/Code/FFmpeg

./ffmpeg -re \
    -f lavfi -i "smptebars=size=1280x720:rate=25:duration=100" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=100" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -x264-params "nal-hrd=cbr:force-cfr=1:bitrate=5000:vbv-maxrate=5000:vbv-bufsize=5000:keyint=50:bframes=0" \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1" \
    -f mpegts "udp://localhost:${UDP_PORT}?pkt_size=1316" \
    2>&1 | tee test_results/aggressive_test.log | grep --line-buffered "SRT Stats"

echo ""
echo "✅ Test complete!"
echo ""

echo "Results:"
docker logs srt-aggressive 2>&1 | grep "Phase"

echo ""
echo "SRT Stats Summary:"
grep "SRT Stats" test_results/aggressive_test.log | awk '{
    if ($0 ~ /BW=/) {
        split($0, a, "BW="); split(a[2], b, " ");
        split($0, c, "Loss="); split(c[2], d, "%");
        print "  " b[1] " Mbps, Loss: " d[1] "%"
    }
}' | tail -20

echo ""
echo "Check VLC - you should have seen artifacts/stuttering in Phase 3!"

