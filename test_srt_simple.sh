#!/bin/bash
#
# Simple SRT + Rate Control Test
# Clean output focusing on bandwidth stats
#

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ENCODER="${1:-libx264}"
SRT_PORT=4200

echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  SRT Rate Control Test - ${ENCODER} with Enhanced libsrt  ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"

mkdir -p test_results
OUTPUT="test_results/${ENCODER}_$(date +%Y%m%d_%H%M%S).ts"
LOG="test_results/test_$(date +%Y%m%d_%H%M%S).log"

# Cleanup
cleanup() {
    echo -e "\n${YELLOW}Stopping test...${NC}"
    docker stop srt-test 2>/dev/null || true
    pkill -f "ffmpeg.*${SRT_PORT}" 2>/dev/null || true
}
trap cleanup EXIT INT

# Start Docker receiver with netem
echo -e "${BLUE}Starting receiver with network simulation...${NC}\n"

docker run -d --name srt-test --cap-add=NET_ADMIN \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    srt-navrc-test \
    bash -c '
        set_bw() {
            tc qdisc del dev eth0 root 2>/dev/null || true
            tc qdisc add dev eth0 root handle 1: htb default 10
            tc class add dev eth0 parent 1: classid 1:10 htb rate $1
            [ "$2" != "" ] && tc qdisc add dev eth0 parent 1:10 netem loss $2%
            printf "\n[%s] BW: %s, Loss: %s%%\n" "$(date +%H:%M:%S)" "$1" "${2:-0}"
        }
        
        ffmpeg -hide_banner -v error -stats \
            -protocol_whitelist file,udp,srt \
            -i "srt://0.0.0.0:4200?mode=listener&latency=200&enable_stats=1" \
            -c copy -f null - 2>&1 &
        
        sleep 5
        printf "\n╔════════════════════════════════════╗\n"
        printf "║   Network Simulation Timeline      ║\n"
        printf "╚════════════════════════════════════╝\n"
        
        set_bw 10mbit
        sleep 20
        
        set_bw 3mbit
        sleep 20
        
        set_bw 1mbit 5
        sleep 20
        
        set_bw 7mbit
        sleep 30
        
        printf "\n✅ Simulation complete\n"
        wait
    '

sleep 3
echo -e "${GREEN}✓ Receiver started${NC}\n"

echo -e "${BLUE}Starting sender (${ENCODER})...${NC}\n"

# Start sender
./ffmpeg -y -v warning -stats -re \
    -f lavfi -i "testsrc=size=1280x720:rate=25:duration=90" \
    -f lavfi -i "sine=frequency=1000:duration=90" \
    -c:v ${ENCODER} -preset veryfast -tune zerolatency \
    -b:v 5M -minrate 500k -maxrate 10M -bufsize 2M \
    -g 50 -bf 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=200&enable_stats=1" \
    -c:v copy -c:a copy -f mpegts "${OUTPUT}" \
    2>&1 | tee "${LOG}" &

SENDER_PID=$!
sleep 2

echo -e "${GREEN}✓ Sender started${NC}"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Monitoring SRT Statistics (90 seconds)${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"

# Monitor stats with timestamps
tail -f "${LOG}" 2>/dev/null | grep --line-buffered -i "srt\|frame=" | while IFS= read -r line; do
    if [[ $line == *"SRT"* ]]; then
        echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $line"
    else
        printf "\r${BLUE}%s${NC}" "$line"
    fi
done &
TAIL_PID=$!

wait $SENDER_PID 2>/dev/null || true
sleep 2
kill $TAIL_PID 2>/dev/null || true

echo -e "\n\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Test Complete${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

# Show Docker logs
echo -e "${CYAN}Network Timeline:${NC}"
docker logs srt-test 2>&1 | grep -E "BW:|Simulation"

echo ""
if [ -f "${LOG}" ]; then
    stats=$(grep -c -i "srt stats" "${LOG}" 2>/dev/null || echo "0")
    echo -e "SRT Stats collected: ${GREEN}${stats}${NC} samples"
    
    if [ $stats -gt 0 ]; then
        echo -e "\n${CYAN}Sample Statistics:${NC}"
        grep -i "srt stats" "${LOG}" | head -5 | while read line; do
            echo "  $line"
        done
        
        if [ $stats -gt 5 ]; then
            echo "  ..."
            grep -i "srt stats" "${LOG}" | tail -3 | while read line; do
                echo "  $line"
            done
        fi
    fi
fi

echo -e "\n${CYAN}Output Files:${NC}"
echo "  Video: ${OUTPUT}"
echo "  Log: ${LOG}"

if [ -f "${OUTPUT}" ]; then
    size=$(ls -lh "${OUTPUT}" | awk '{print $5}')
    echo -e "\n  File size: ${size}"
    echo -e "  Play with: ${GREEN}./ffplay ${OUTPUT}${NC}"
fi

echo -e "\n${GREEN}✅ Test completed successfully!${NC}\n"

