#!/bin/bash
#
# Working Netem Test - Shows SRT stats in real-time
# Based on your libsrt netem approach
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     SRT + Enhanced libsrt + Netem Test (REAL-TIME)          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

cleanup() {
    echo "Cleaning up..."
    docker stop srt-netem-live 2>/dev/null || true
}
trap cleanup EXIT INT

echo "Starting test container..."
echo ""

docker run --rm --name srt-netem-live --cap-add=NET_ADMIN \
    ffmpeg-enhanced-srt \
    bash -c '
set -e

apply_netem() {
    local rate=$1
    local delay=$2
    local loss=$3
    local label=$4
    local duration=$5
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $label"
    echo "  Rate: $rate | Delay: ${delay}ms | Loss: $loss%"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Clear old rules
    tc qdisc del dev lo root 2>/dev/null || true
    
    # Add HTB + class + netem
    tc qdisc add dev lo root handle 1: htb default 10
    tc class add dev lo parent 1: classid 1:10 htb rate ${rate}
    
    if [ "$delay" != "0" ] || [ "$loss" != "0" ]; then
        local netem_opts=""
        [ "$delay" != "0" ] && netem_opts="delay ${delay}ms"
        [ "$loss" != "0" ] && netem_opts="$netem_opts loss ${loss}%"
        tc qdisc add dev lo parent 1:10 handle 10: netem $netem_opts
    fi
    
    echo "Monitoring SRT stats for ${duration}s..."
    sleep $duration
}

echo "Starting receiver..."
ffmpeg -hide_banner -loglevel info \
    -protocol_whitelist file,udp,srt \
    -i "srt://0.0.0.0:4200?mode=listener&latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1" \
    -c copy -f null - 2>&1 | grep --line-buffered "SRT Stats" &
RX_PID=$!

sleep 3
echo "Receiver started (PID: $RX_PID)"
echo ""

echo "Starting sender..."
timeout 90 ffmpeg -re \
    -f lavfi -i "testsrc=duration=90:size=640x480:rate=25" \
    -c:v libx264 -preset ultrafast -b:v 2M \
    -f mpegts "srt://127.0.0.1:4200?latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1" \
    2>&1 | grep --line-buffered -E "SRT Stats|frame=" &
TX_PID=$!

sleep 5
echo "Sender started (PID: $TX_PID)"
echo ""

apply_netem "10mbit" 0 0 "PHASE 1: Excellent (10 Mbps)" 20
apply_netem "3mbit" 50 2 "PHASE 2: Moderate (3 Mbps + 50ms + 2% loss)" 20
apply_netem "1mbit" 100 10 "PHASE 3: SEVERE (1 Mbps + 100ms + 10% loss)" 20
apply_netem "8mbit" 20 0 "PHASE 4: Recovery (8 Mbps + 20ms)" 20

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TEST COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Clean up
tc qdisc del dev lo root 2>/dev/null || true
kill $TX_PID $RX_PID 2>/dev/null || true
'

echo ""
echo "✅ Test finished!"

