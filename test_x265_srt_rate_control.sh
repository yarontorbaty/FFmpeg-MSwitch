#!/bin/bash
#
# Visual SRT Rate Control Test for libx265
# Similar to x264 test but for x265 encoder
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    libx265 + SRT: Real-Time Rate Control Visual Test             ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Configuration
FFMPEG="/Users/yarontorbaty/Documents/Code/FFmpeg/ffmpeg"
FFPLAY="/Users/yarontorbaty/Documents/Code/FFmpeg/ffplay"
SRT_PORT=4201
VIDEO_SIZE="1280x720"
FRAMERATE=25

# Rate parameters
INITIAL_BITRATE=5000000  # bps
MIN_BITRATE=500000       # bps
MAX_BITRATE=10000000     # bps
SRT_LATENCY=200          # ms

# Test directory
TEST_DIR="/Users/yarontorbaty/Documents/Code/FFmpeg/test_results"
mkdir -p "${TEST_DIR}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_TS="${TEST_DIR}/x265_rate_control_${TIMESTAMP}.ts"
STATS_LOG="${TEST_DIR}/stats_x265_${TIMESTAMP}.log"

echo -e "${CYAN}Configuration:${NC}"
echo "  • Encoder: libx265"
echo "  • Resolution: ${VIDEO_SIZE} @ ${FRAMERATE}fps"
echo "  • Bitrate: $(($MIN_BITRATE/1000))k - $(($MAX_BITRATE/1000000))M (starting: $(($INITIAL_BITRATE/1000000))M)"
echo "  • SRT Latency: ${SRT_LATENCY}ms"
echo "  • Output: ${OUTPUT_TS}"
echo ""
echo -e "${YELLOW}Note: x265 has limited runtime bitrate control${NC}"
echo -e "${YELLOW}This test primarily validates SRT statistics monitoring${NC}"
echo ""

# Cleanup
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    docker stop srt-netem-receiver-x265 2>/dev/null || true
    pkill -f "ffmpeg.*${SRT_PORT}" 2>/dev/null || true
    pkill -f "ffplay" 2>/dev/null || true
    echo "Done"
}

trap cleanup EXIT INT TERM

# Check Docker
if ! docker info &> /dev/null; then
    echo -e "${RED}❌ Docker not running${NC}"
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

# Start Docker receiver
docker run -d \
    --name srt-netem-receiver-x265 \
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
                echo "[$(date +%H:%M:%S)] Network: $1, Loss: $2%"
            fi
        }
        
        echo "[RECEIVER] Starting SRT listener for x265..."
        ffmpeg -hide_banner -loglevel info \
            -protocol_whitelist file,udp,srt \
            -i "srt://0.0.0.0:'${SRT_PORT}'?mode=listener&latency='${SRT_LATENCY}'&enable_stats=1" \
            -c copy -f null - 2>&1 | grep --line-buffered "SRT Stats" &
        
        sleep 5
        
        echo "Phase 1: 10 Mbps (20s)"
        apply_netem 10mbit 0
        sleep 20
        
        echo "Phase 2: 3 Mbps (20s)"
        apply_netem 3mbit 0
        sleep 20
        
        echo "Phase 3: 1 Mbps + loss (20s)"
        apply_netem 1mbit 5
        sleep 20
        
        echo "Phase 4: 7 Mbps (20s)"
        apply_netem 7mbit 0
        sleep 20
        
        echo "Complete"
        wait
    '

sleep 5

echo -e "${GREEN}✓ Receiver started${NC}"
echo ""

echo -e "${BLUE}Starting x265 encoder...${NC}"

# Start sender
"${FFMPEG}" -y \
    -f lavfi -i "
        color=c=0x1a1a2e:s=${VIDEO_SIZE}:r=${FRAMERATE}:d=80[bg];
        [bg]drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='libx265 + SRT Test':\
fontsize=52:fontcolor=white:box=1:boxcolor=0x16213e@0.9:\
x=(w-text_w)/2:y=60,
drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='Bitrate\\: $(($INITIAL_BITRATE/1000000))M → $(($MIN_BITRATE/1000))k':\
fontsize=38:fontcolor=0xf39c12:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=180,
drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='Phase\\: %{eif\\:floor(t/20)+1\\:d}/4':\
fontsize=34:fontcolor=0x06ffa5:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=280,
drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='Time\\: %{pts\\:gmtime\\:0\\:%M\\\\:%S}':\
fontsize=30:fontcolor=white:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=h-80
    " \
    -f lavfi -i "sine=frequency=800:sample_rate=48000:duration=80" \
    -map 0:v -map 1:a \
    -c:v libx265 \
    -preset veryfast \
    -tune zerolatency \
    -b:v ${INITIAL_BITRATE} \
    -minrate ${MIN_BITRATE} \
    -maxrate ${MAX_BITRATE} \
    -bufsize 2M \
    -g 50 \
    -x265-params "keyint=50:bframes=0" \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=${SRT_LATENCY}&enable_stats=1" \
    -map 0:v -map 1:a \
    -c:v copy -c:a copy \
    -f mpegts "${OUTPUT_TS}" \
    2>&1 | tee "${STATS_LOG}" &

SENDER_PID=$!

echo -e "${GREEN}✓ Sender started${NC}"
echo ""
echo -e "${YELLOW}Monitoring (80 seconds)...${NC}"
echo ""

# Monitor stats
tail -f "${STATS_LOG}" 2>/dev/null | grep --line-buffered "SRT Stats" | while read line; do
    echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $line"
done &
TAIL_PID=$!

wait $SENDER_PID 2>/dev/null || true
kill $TAIL_PID 2>/dev/null || true

echo ""
echo -e "${GREEN}✅ Test complete!${NC}"
echo ""
echo "Output: ${OUTPUT_TS}"
echo "Stats: ${STATS_LOG}"
echo ""
echo "Play with: ${FFPLAY} ${OUTPUT_TS}"

