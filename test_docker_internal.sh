#!/bin/bash
#
# Complete Internal Docker Test - Sender + Receiver inside container
# Based on libsrt netem approach
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   FFmpeg SRT Rate Control - Internal Docker Test            ║"
echo "║   (Both sender and receiver inside container)                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

SRT_PORT=4200

cleanup() {
    echo "Cleaning up..."
    docker stop srt-internal-test 2>/dev/null || true
    docker rm srt-internal-test 2>/dev/null || true
}
trap cleanup EXIT INT

echo "Starting Docker container with complete test..."
echo ""

docker run --rm --name srt-internal-test --cap-add=NET_ADMIN \
    ffmpeg-enhanced-srt \
    bash -c '
set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              Inside Docker Container                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

apply_netem() {
    local rate=$1
    local delay=$2
    local loss=$3
    local label=$4
    local duration=$5
    
    # Remove existing rules
    tc qdisc del dev lo root 2>/dev/null || true
    
    # Add HTB qdisc and class
    tc qdisc add dev lo root handle 1: htb default 10
    tc class add dev lo parent 1: classid 1:10 htb rate ${rate}
    
    # Add netem for delay and loss if specified
    if [ "$delay" != "0" ] || [ "$loss" != "0" ]; then
        local netem_opts=""
        [ "$delay" != "0" ] && netem_opts="delay ${delay}ms"
        [ "$loss" != "0" ] && netem_opts="$netem_opts loss ${loss}%"
        tc qdisc add dev lo parent 1:10 handle 10: netem $netem_opts
    fi
    
    echo ""
    echo "┌────────────────────────────────────────────────────────┐"
    printf "│ %-54s │\n" "$label"
    printf "│ %-54s │\n" "  Rate: $rate, Delay: ${delay}ms, Loss: $loss%"
    echo "└────────────────────────────────────────────────────────┘"
    tc qdisc show dev lo | head -3 | sed "s/^/  /"
    echo ""
    
    sleep $duration
}

# Start receiver with small buffers in background
echo "[1/2] Starting FFmpeg SRT receiver..."
/ffmpeg/ffmpeg -hide_banner -v info \
    -protocol_whitelist file,udp,srt \
    -i "srt://127.0.0.1:${SRT_PORT}?mode=listener&latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1" \
    -c copy -f null - \
    > /tmp/receiver.log 2>&1 &
RECEIVER_PID=$!
sleep 3
echo "   ✓ Receiver started (PID: $RECEIVER_PID)"
echo "   ✓ Small buffers (100ms latency, 500KB buffers)"
echo ""

# Start sender in background
echo "[2/2] Starting FFmpeg CBR sender (5 Mbps)..."
/usr/local/bin/ffmpeg -re \
    -f lavfi -i "smptebars=size=1280x720:rate=25:duration=100" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=100" \
    -c:v libx264 \
    -preset veryfast -tune zerolatency \
    -x264-params "nal-hrd=cbr:force-cfr=1:bitrate=5000:vbv-maxrate=5000:vbv-bufsize=5000:keyint=50:bframes=0" \
    -c:a aac -b:a 128k \
    -f mpegts "srt://127.0.0.1:${SRT_PORT}?latency=100&rcvbuf=500000&sndbuf=500000&enable_stats=1" \
    > /tmp/sender.log 2>&1 &
SENDER_PID=$!
sleep 5
echo "   ✓ Sender started (PID: $SENDER_PID)"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "             Network Simulation Phases"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Apply network conditions in phases
apply_netem "10mbit" 0 0 "PHASE 1: Excellent (10 Mbps)" 20 &
PHASE_PID=$!

# Monitor logs during each phase
monitor_logs() {
    local phase_name=$1
    local phase_pid=$2
    
    echo ""
    echo "SRT Stats during $phase_name:"
    while kill -0 $phase_pid 2>/dev/null; do
        sleep 3
        tail -5 /tmp/sender.log 2>/dev/null | grep "SRT Stats" | tail -1 | sed "s/^/  /"
    done
}

monitor_logs "Phase 1" $PHASE_PID

apply_netem "3mbit" 50 2 "PHASE 2: Moderate (3 Mbps + 50ms + 2% loss)" 20 &
PHASE_PID=$!
monitor_logs "Phase 2" $PHASE_PID

apply_netem "1mbit" 100 10 "PHASE 3: SEVERE (1 Mbps + 100ms + 10% loss)" 20 &
PHASE_PID=$!
monitor_logs "Phase 3" $PHASE_PID

apply_netem "8mbit" 20 0 "PHASE 4: Recovery (8 Mbps + 20ms)" 20 &
PHASE_PID=$!
monitor_logs "Phase 4" $PHASE_PID

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Stop processes
echo "Stopping sender and receiver..."
kill $SENDER_PID 2>/dev/null || true
sleep 1
kill $RECEIVER_PID 2>/dev/null || true
sleep 1

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                       RESULTS                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "Sender SRT Stats:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
grep "SRT Stats" /tmp/sender.log 2>/dev/null | tail -20 | sed "s/^/  /"
echo ""

echo "Receiver SRT Stats:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
grep "SRT Stats" /tmp/receiver.log 2>/dev/null | tail -20 | sed "s/^/  /"
echo ""

echo "✅ Test complete! Check stats above for bandwidth variations."
'

echo ""
echo "Test finished!"

