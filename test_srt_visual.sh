#!/bin/bash
#
# Simple Visual SRT Rate Control Test
# Shows bandwidth statistics while streaming
#

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

FFMPEG="./ffmpeg"
SRT_PORT=4200
ENCODER="${1:-libx264}"
TEST_DURATION=90

echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  SRT Rate Control Test - ${ENCODER}                   ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Test directory
TEST_DIR="./test_results"
mkdir -p "${TEST_DIR}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT="${TEST_DIR}/${ENCODER}_${TIMESTAMP}.ts"
LOG="${TEST_DIR}/log_${TIMESTAMP}.txt"

echo "Configuration:"
echo "  Encoder: ${ENCODER}"
echo "  Duration: ${TEST_DURATION}s"
echo "  Output: ${OUTPUT}"
echo ""

# Cleanup
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker stop srt-test 2>/dev/null || true
    pkill -f "ffmpeg.*${SRT_PORT}" 2>/dev/null || true
}
trap cleanup EXIT

# Check Docker
if ! docker info &> /dev/null; then
    echo -e "${RED}Docker not running${NC}"
    exit 1
fi

# Build image if needed
if ! docker images | grep -q "srt-navrc-test"; then
    echo "Building Docker image..."
    cd /Users/yarontorbaty/Documents/Code/srt
    docker build -t srt-navrc-test -f _test/Dockerfile .
    cd - > /dev/null
fi

echo -e "${GREEN}✓ Docker ready${NC}\n"

# Start receiver with network simulation
echo -e "${BLUE}Starting receiver with network simulation...${NC}\n"

docker run -d --name srt-test --cap-add=NET_ADMIN \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    srt-navrc-test \
    bash -c '
        set_bandwidth() {
            tc qdisc del dev eth0 root 2>/dev/null || true
            tc qdisc add dev eth0 root handle 1: htb default 10
            tc class add dev eth0 parent 1: classid 1:10 htb rate $1
            [ "$2" != "0" ] && tc qdisc add dev eth0 parent 1:10 netem loss $2%
            echo "[$(date +%H:%M:%S)] Network: $1, Loss: $2%"
        }
        
        ffmpeg -hide_banner -protocol_whitelist file,udp,srt \
            -i "srt://0.0.0.0:'${SRT_PORT}'?mode=listener&latency=200&enable_stats=1" \
            -c copy -f null - 2>&1 | grep --line-buffered -E "SRT Stats|frame=" &
        
        sleep 5
        echo "Phase 1: 10 Mbps"
        set_bandwidth 10mbit 0
        sleep 20
        
        echo "Phase 2: 3 Mbps"  
        set_bandwidth 3mbit 0
        sleep 20
        
        echo "Phase 3: 1 Mbps + 5% loss"
        set_bandwidth 1mbit 5
        sleep 20
        
        echo "Phase 4: 7 Mbps"
        set_bandwidth 7mbit 0
        sleep 30
        
        echo "Done"
        wait
    '

sleep 5

echo -e "${GREEN}✓ Receiver running${NC}\n"

echo -e "${BLUE}Starting sender...${NC}\n"

# Simple test pattern with text
"${FFMPEG}" -y -re \
    -f lavfi -i "testsrc=size=1280x720:rate=25:duration=${TEST_DURATION}" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=${TEST_DURATION}" \
    -vf "drawtext=text='${ENCODER} SRT Test - Watch console for stats':fontsize=40:fontcolor=white:x=(w-text_w)/2:y=h/2:box=1:boxcolor=black@0.7" \
    -c:v ${ENCODER} -preset veryfast -tune zerolatency \
    -b:v 5M -minrate 500k -maxrate 10M -bufsize 2M \
    -g 50 -bf 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=200&enable_stats=1" \
    -c:v copy -c:a copy -f mpegts "${OUTPUT}" \
    2>&1 | tee "${LOG}" &

SENDER_PID=$!

echo -e "${GREEN}✓ Sender started (PID: ${SENDER_PID})${NC}"
echo ""
echo -e "${YELLOW}Monitoring for ${TEST_DURATION} seconds...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Monitor stats
tail -f "${LOG}" 2>/dev/null | grep --line-buffered "SRT Stats" | while read line; do
    echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $line"
done &
TAIL_PID=$!

wait $SENDER_PID 2>/dev/null || true
sleep 2
kill $TAIL_PID 2>/dev/null || true

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Results${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Analyze
if [ -f "${LOG}" ]; then
    count=$(grep -c "SRT Stats" "${LOG}" || echo "0")
    echo "Statistics collected: ${count} samples"
    
    if [ $count -gt 0 ]; then
        echo ""
        echo "Sample statistics:"
        grep "SRT Stats" "${LOG}" | head -10
    fi
fi

echo ""
echo "Docker receiver log:"
docker logs srt-test 2>&1 | grep -E "Phase|Network:" | tail -10

echo ""
echo "Output: ${OUTPUT}"
echo "Log: ${LOG}"
echo ""
echo -e "${GREEN}✅ Test complete! Play with: ./ffplay ${OUTPUT}${NC}"

