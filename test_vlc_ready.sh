#!/bin/bash
#
# VLC Ready Test - Ensures VLC is buffering before starting
#

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

UDP_PORT=5000
SRT_PORT=4200
ENCODER="libx264"

echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  VLC Live Preview - Enhanced SRT Rate Control Test   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}\n"

mkdir -p test_results

# Cleanup
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker stop srt-receiver 2>/dev/null || true
    pkill -f "ffmpeg.*${SRT_PORT}" 2>/dev/null || true
}
trap cleanup EXIT INT

# Kill any existing VLC on port 5000
pkill -f "VLC.*udp" 2>/dev/null || true
sleep 1

# Step 1: Open VLC
echo -e "${CYAN}Step 1: Opening VLC...${NC}\n"

if [ -f /Applications/VLC.app/Contents/MacOS/VLC ]; then
    /Applications/VLC.app/Contents/MacOS/VLC udp://@:${UDP_PORT} > /dev/null 2>&1 &
    VLC_PID=$!
    echo -e "${GREEN}✓ VLC opened (PID: ${VLC_PID})${NC}"
    echo "  Listening on: udp://@:${UDP_PORT}"
    sleep 3
else
    echo -e "${RED}✗ VLC not found${NC}"
    echo "  Please open VLC manually:"
    echo "    File → Open Network → udp://@:${UDP_PORT}"
    echo ""
    echo "Press Enter when ready..."
    read
fi

# Step 2: Start Docker receiver
echo -e "\n${CYAN}Step 2: Starting SRT receiver...${NC}\n"

docker run -d --name srt-receiver --cap-add=NET_ADMIN \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    srt-navrc-test \
    bash -c '
        ffmpeg -hide_banner -v info \
            -protocol_whitelist file,udp,srt \
            -i "srt://0.0.0.0:4200?mode=listener&latency=200&enable_stats=1" \
            -c copy -f null - 2>&1 | grep --line-buffered "SRT Stats" &
        
        sleep 8
        
        # Network simulation
        tc qdisc add dev eth0 root handle 1: htb default 10
        
        echo "[$(date +%H:%M:%S)] Starting: 10 Mbps"
        tc class add dev eth0 parent 1: classid 1:10 htb rate 10mbit
        sleep 25
        
        echo "[$(date +%H:%M:%S)] Degrading: 2 Mbps"
        tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 2mbit
        sleep 25
        
        echo "[$(date +%H:%M:%S)] Recovering: 8 Mbps"
        tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 8mbit
        sleep 25
        
        echo "[$(date +%H:%M:%S)] Complete"
        wait
    '

sleep 3
echo -e "${GREEN}✓ Receiver ready${NC}\n"

# Step 3: Stream
echo -e "${CYAN}Step 3: Starting stream...${NC}\n"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  CHECK VLC - You should see a test pattern!${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}\n"

./ffmpeg -re -v warning -stats \
    -f lavfi -i "testsrc=size=1280x720:rate=25:duration=75,format=yuv420p" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=75" \
    -c:v ${ENCODER} -preset ultrafast -tune zerolatency \
    -b:v 5M -minrate 500k -maxrate 10M -bufsize 1M \
    -g 50 -bf 0 -sc_threshold 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=200&enable_stats=1" \
    -f mpegts "udp://localhost:${UDP_PORT}?pkt_size=1316" \
    2>&1 | tee test_results/vlc_final.log

echo -e "\n${GREEN}✅ Stream complete!${NC}\n"

echo "Network log:"
docker logs srt-receiver 2>&1 | grep ":" | tail -10

echo ""
echo -e "${CYAN}To replay: ./ffplay test_results/vlc_auto_*.ts${NC}\n"

