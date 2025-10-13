#!/bin/bash
#
# Visual SRT Rate Control Test for libx264
# Demonstrates real-time bitrate adaptation with network simulation
# Uses x264's TCP control port for actual bitrate changes
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    libx264 + SRT: Real-Time Rate Control Visual Test             ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Configuration
FFMPEG="/Users/yarontorbaty/Documents/Code/FFmpeg/ffmpeg"
FFPLAY="/Users/yarontorbaty/Documents/Code/FFmpeg/ffplay"
SRT_PORT=4200
X264_CONTROL_PORT=9999
VIDEO_SIZE="1280x720"
FRAMERATE=25

# Rate parameters
INITIAL_BITRATE=5000  # kbps
MIN_BITRATE=500       # kbps
MAX_BITRATE=10000     # kbps
SRT_LATENCY=200       # ms

# Test directory
TEST_DIR="/Users/yarontorbaty/Documents/Code/FFmpeg/test_results"
mkdir -p "${TEST_DIR}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_TS="${TEST_DIR}/x264_rate_control_${TIMESTAMP}.ts"
STATS_LOG="${TEST_DIR}/stats_${TIMESTAMP}.log"

echo -e "${CYAN}Configuration:${NC}"
echo "  • Encoder: libx264 with TCP control on port ${X264_CONTROL_PORT}"
echo "  • Resolution: ${VIDEO_SIZE} @ ${FRAMERATE}fps"
echo "  • Bitrate: ${MIN_BITRATE}k - ${MAX_BITRATE}k (starting: ${INITIAL_BITRATE}k)"
echo "  • SRT Latency: ${SRT_LATENCY}ms"
echo "  • Output: ${OUTPUT_TS}"
echo ""

# Cleanup
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    docker stop srt-netem-receiver 2>/dev/null || true
    pkill -f "ffmpeg.*${SRT_PORT}" 2>/dev/null || true
    pkill -f "ffplay" 2>/dev/null || true
    rm -f /tmp/x264_control_${X264_CONTROL_PORT}
    echo "Done"
}

trap cleanup EXIT INT TERM

# Check Docker
if ! docker info &> /dev/null; then
    echo -e "${RED}❌ Docker not running. Start Docker Desktop.${NC}"
    exit 1
fi

# Build Docker if needed
if ! docker images | grep -q "srt-navrc-test"; then
    echo -e "${YELLOW}Building Docker image...${NC}"
    cd /Users/yarontorbaty/Documents/Code/srt
    docker build -t srt-navrc-test -f _test/Dockerfile . || exit 1
    cd - > /dev/null
fi

echo -e "${GREEN}✓ Docker ready${NC}"
echo ""

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Starting Docker receiver with network simulation${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Start Docker receiver with netem
docker run -d \
    --name srt-netem-receiver \
    --cap-add=NET_ADMIN \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    srt-navrc-test \
    bash -c '
        apply_netem() {
            tc qdisc del dev eth0 root 2>/dev/null || true
            if [ "$1" != "unlimited" ]; then
                tc qdisc add dev eth0 root handle 1: htb default 10
                tc class add dev eth0 parent 1: classid 1:10 htb rate $1
                [ "$2" != "0" ] && tc qdisc add dev eth0 parent 1:10 netem loss $2%
                echo "[$(date +%H:%M:%S)] Applied: $1 bandwidth, $2% loss"
            else
                echo "[$(date +%H:%M:%S)] Removed bandwidth limit"
            fi
        }
        
        echo "[RECEIVER] Starting SRT listener..."
        ffmpeg -hide_banner -loglevel info \
            -protocol_whitelist file,udp,srt \
            -i "srt://0.0.0.0:'${SRT_PORT}'?mode=listener&latency='${SRT_LATENCY}'&enable_stats=1&pkt_size=1316" \
            -c copy -f null - 2>&1 | grep --line-buffered "SRT Stats" &
        
        sleep 5
        
        echo ""
        echo "Network Simulation Timeline:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        echo "Phase 1: 10 Mbps (0-20s)"
        apply_netem 10mbit 0
        sleep 20
        
        echo "Phase 2: 3 Mbps (20-40s)"
        apply_netem 3mbit 0
        sleep 20
        
        echo "Phase 3: 1 Mbps + 5% loss (40-60s)"  
        apply_netem 1mbit 5
        sleep 20
        
        echo "Phase 4: 7 Mbps recovery (60-80s)"
        apply_netem 7mbit 0
        sleep 20
        
        echo "Phase 5: Full speed (80-90s)"
        apply_netem unlimited 0
        sleep 10
        
        echo "Network simulation complete"
        wait
    '

sleep 5

echo -e "${GREEN}✓ Receiver started${NC}"
echo ""

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Starting sender with visual output${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Create animated test pattern showing current phase
"${FFMPEG}" -y \
    -f lavfi -i "
        color=c=0x2c3e50:s=${VIDEO_SIZE}:r=${FRAMERATE}:d=90[base];
        [base]drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='libx264 + SRT Rate Control Test':\
fontsize=56:fontcolor=white:box=1:boxcolor=0x3498db@0.9:\
x=(w-text_w)/2:y=60,
drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='Initial Bitrate\\: ${INITIAL_BITRATE} kbps':\
fontsize=40:fontcolor=0xf39c12:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=180,
drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='Network Phase\\: %{eif\\:floor(t/20)+1\\:d} of 5':\
fontsize=36:fontcolor=0x2ecc71:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=280,
drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='Time\\: %{pts\\:gmtime\\:0\\:%M\\\\:%S}':\
fontsize=32:fontcolor=0xecf0f1:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=380,
drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='Watch bandwidth stats below!':\
fontsize=28:fontcolor=0xe74c3c:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=h-80
    " \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=90" \
    -map 0:v -map 1:a \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -x264-params "nal-hrd=cbr:force-cfr=1:bitrate=${INITIAL_BITRATE}:vbv-maxrate=${INITIAL_BITRATE}:vbv-bufsize=${INITIAL_BITRATE}" \
    -x264opts "tcp-port=${X264_CONTROL_PORT}" \
    -g 50 \
    -bf 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=${SRT_LATENCY}&enable_stats=1&pkt_size=1316" \
    -map 0:v -map 1:a \
    -c:v copy -c:a copy \
    -f mpegts "${OUTPUT_TS}" \
    2>&1 | tee "${STATS_LOG}" &

SENDER_PID=$!

echo -e "${GREEN}✓ Sender started (PID: ${SENDER_PID})${NC}"
echo -e "${GREEN}✓ x264 TCP control port: ${X264_CONTROL_PORT}${NC}"
echo ""

# Wait a bit for stream to stabilize
sleep 3

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Monitoring SRT Statistics (90 second test)${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Network phases:"
echo "  ${CYAN}Phase 1${NC} (0-20s):   10 Mbps   - Excellent"
echo "  ${CYAN}Phase 2${NC} (20-40s):  3 Mbps    - Should adapt down"
echo "  ${CYAN}Phase 3${NC} (40-60s):  1 Mbps    - Emergency mode"
echo "  ${CYAN}Phase 4${NC} (60-80s):  7 Mbps    - Recovery"
echo "  ${CYAN}Phase 5${NC} (80-90s):  Unlimited - Full recovery"
echo ""

# Monitor stats in real-time
tail -f "${STATS_LOG}" 2>/dev/null | while read line; do
    if [[ $line == *"SRT Stats"* ]]; then
        timestamp=$(date +%H:%M:%S)
        echo -e "${GREEN}[${timestamp}]${NC} $line"
    fi
done &
TAIL_PID=$!

# Wait for test to complete
wait $SENDER_PID 2>/dev/null || true

kill $TAIL_PID 2>/dev/null || true

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Test Complete - Results Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Show Docker receiver logs
echo -e "${CYAN}Docker receiver network log:${NC}"
docker logs srt-netem-receiver 2>&1 | grep -E "\[NETEM\]|\[RECEIVER\]" | tail -20

echo ""
echo -e "${CYAN}SRT Statistics Summary:${NC}"
if [ -f "${STATS_LOG}" ]; then
    stats_count=$(grep -c "SRT Stats" "${STATS_LOG}" || echo "0")
    echo "  • Total measurements: ${stats_count}"
    
    if [ $stats_count -gt 5 ]; then
        echo ""
        echo "  First 5 samples:"
        grep "SRT Stats" "${STATS_LOG}" | head -5 | sed 's/^/    /'
        echo ""
        echo "  Last 5 samples:"
        grep "SRT Stats" "${STATS_LOG}" | tail -5 | sed 's/^/    /'
    fi
fi

echo ""
echo -e "${GREEN}Files created:${NC}"
ls -lh "${OUTPUT_TS}" "${STATS_LOG}" 2>/dev/null || true

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}To view the recorded output:${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  ${FFPLAY} ${OUTPUT_TS}"
echo ""
echo -e "${GREEN}✅ Test complete!${NC}"

