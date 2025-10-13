#!/bin/bash
#
# Auto VLC Test - Opens VLC automatically
#

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

UDP_PORT=5000
SRT_PORT=4200
ENCODER="libx264"

echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Auto VLC Test - Enhanced SRT + ${ENCODER}         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}\n"

mkdir -p test_results
OUTPUT="test_results/vlc_auto_$(date +%H%M%S).ts"

# Cleanup
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker stop srt-vlc-auto 2>/dev/null || true
    pkill -f "ffmpeg.*${SRT_PORT}" 2>/dev/null || true
    pkill -f "VLC.*udp" 2>/dev/null || true
}
trap cleanup EXIT INT

# Start Docker receiver
echo -e "${CYAN}Step 1: Starting SRT receiver with network simulation${NC}\n"

docker run -d --name srt-vlc-auto --cap-add=NET_ADMIN \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    srt-navrc-test \
    bash -c '
        ffmpeg -hide_banner -v error -stats \
            -protocol_whitelist file,udp,srt \
            -i "srt://0.0.0.0:4200?mode=listener&latency=200&enable_stats=1" \
            -c copy -f null - 2>&1 &
        
        sleep 5
        
        # Apply network limits
        tc qdisc add dev eth0 root handle 1: htb default 10
        tc class add dev eth0 parent 1: classid 1:10 htb rate 10mbit
        echo "[$(date +%H:%M:%S)] Phase 1: 10 Mbps"
        sleep 25
        
        tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 2mbit
        echo "[$(date +%H:%M:%S)] Phase 2: 2 Mbps (watch quality drop)"
        sleep 25
        
        tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 8mbit
        echo "[$(date +%H:%M:%S)] Phase 3: 8 Mbps (recovery)"
        sleep 20
        
        echo "[$(date +%H:%M:%S)] Test complete"
        wait
    '

sleep 3
echo -e "${GREEN}✓ Receiver ready${NC}\n"

# Start FFmpeg streaming
echo -e "${CYAN}Step 2: Starting FFmpeg encoder${NC}\n"

./ffmpeg -y -re -v warning -stats \
    -f lavfi -i "testsrc=size=1280x720:rate=25:duration=70" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=70" \
    -c:v ${ENCODER} -preset ultrafast -tune zerolatency \
    -b:v 5M -minrate 500k -maxrate 10M -bufsize 1M \
    -g 50 -bf 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=200&enable_stats=1&pkt_size=1316" \
    -c:v copy -c:a copy -f mpegts "udp://localhost:${UDP_PORT}?pkt_size=1316" \
    -c:v copy -c:a copy -f mpegts "${OUTPUT}" \
    2>&1 | tee test_results/vlc_auto.log &

FFMPEG_PID=$!
sleep 2

echo -e "${GREEN}✓ Stream started (PID: ${FFMPEG_PID})${NC}\n"

# Open VLC automatically
echo -e "${CYAN}Step 3: Opening VLC...${NC}\n"

if [ -f /Applications/VLC.app/Contents/MacOS/VLC ]; then
    /Applications/VLC.app/Contents/MacOS/VLC udp://@:${UDP_PORT} > /dev/null 2>&1 &
    VLC_PID=$!
    echo -e "${GREEN}✓ VLC opened (PID: ${VLC_PID})${NC}"
else
    echo -e "${YELLOW}⚠ VLC not found at /Applications/VLC.app${NC}"
    echo -e "  Please open VLC manually and play: ${CYAN}udp://@:${UDP_PORT}${NC}"
fi

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              TEST RUNNING (70 seconds)                 ║${NC}"
echo -e "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║  VLC should show: Test pattern video                  ║${NC}"
echo -e "${CYAN}║                                                        ║${NC}"
echo -e "${CYAN}║  Network Timeline:                                     ║${NC}"
echo -e "${CYAN}║    0-25s:  10 Mbps  (Excellent - smooth)              ║${NC}"
echo -e "${CYAN}║   25-50s:  2 Mbps   (Poor - may see degradation)      ║${NC}"
echo -e "${CYAN}║   50-70s:  8 Mbps   (Recovery - smooth again)         ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}\n"

# Monitor in terminal
echo -e "${YELLOW}Streaming... (Ctrl+C to stop)${NC}\n"

tail -f test_results/vlc_auto.log 2>/dev/null | grep --line-buffered "frame=" | \
while read line; do
    # Show progress every few seconds
    printf "\r${line}"
done &
TAIL_PID=$!

wait $FFMPEG_PID 2>/dev/null || true
sleep 1
kill $TAIL_PID 2>/dev/null || true

echo -e "\n\n${GREEN}✅ Test complete!${NC}\n"

echo "Network phases from Docker:"
docker logs srt-vlc-auto 2>&1 | grep "Phase"

echo ""
echo "Output saved: ${OUTPUT}"
echo "Log: test_results/vlc_auto.log"
echo ""
echo -e "${CYAN}Replay with: ./ffplay ${OUTPUT}${NC}\n"

