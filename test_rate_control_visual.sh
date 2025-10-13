#!/bin/bash
#
# Visual Rate Control Test with Docker netem
# Tests FFmpeg rate control adaptation with real-time bitrate overlay
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   FFmpeg SRT Rate Control Test with Visual Feedback         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Configuration
FFMPEG_BIN="/Users/yarontorbaty/Documents/Code/FFmpeg/ffmpeg"
SRT_PORT=4200
TEST_DURATION=60
VIDEO_SIZE="1280x720"
ENCODER="${1:-libx264}"  # libx264 or libx265
OUTPUT_FILE="test_rate_control_${ENCODER}_$(date +%Y%m%d_%H%M%S).ts"

# Rate control parameters
INITIAL_BITRATE="5M"
MIN_BITRATE="500k"
MAX_BITRATE="10M"
SRT_LATENCY=200  # Small buffer for quick response

echo -e "${BLUE}Configuration:${NC}"
echo "  • Encoder: $ENCODER"
echo "  • Initial Bitrate: $INITIAL_BITRATE"
echo "  • Bitrate Range: $MIN_BITRATE - $MAX_BITRATE"
echo "  • SRT Latency: ${SRT_LATENCY}ms (small buffer)"
echo "  • Test Duration: ${TEST_DURATION}s"
echo "  • Output: $OUTPUT_FILE"
echo ""

# Check if Docker is running
if ! docker info &> /dev/null; then
    echo -e "${RED}❌ Docker is not running${NC}"
    echo "Please start Docker Desktop and try again"
    exit 1
fi

echo -e "${GREEN}✓ Docker is running${NC}"
echo ""

# Check if Docker image exists
if ! docker images | grep -q "srt-navrc-test"; then
    echo -e "${YELLOW}Docker image not found. Building...${NC}"
    cd /Users/yarontorbaty/Documents/Code/srt
    docker build -t srt-navrc-test -f _test/Dockerfile .
    cd - > /dev/null
fi

echo -e "${GREEN}✓ Docker image ready${NC}"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    docker stop srt-receiver 2>/dev/null || true
    docker stop srt-netem 2>/dev/null || true
    pkill -f "ffmpeg.*srt://.*${SRT_PORT}" || true
    echo "Done"
}

trap cleanup EXIT INT TERM

# Create a network scenario script
cat > /tmp/netem_scenario.sh << 'EOF'
#!/bin/bash
echo "Starting network simulation..."
echo ""

# Start with good bandwidth
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 1 (0-15s): Good network - 10 Mbps"
tc qdisc add dev lo root handle 1: htb default 10
tc class add dev lo parent 1: classid 1:10 htb rate 10mbit
sleep 15

# Degrade to 3 Mbps
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 2 (15-30s): Degraded - 3 Mbps"
tc qdisc del dev lo root
tc qdisc add dev lo root handle 1: htb default 10
tc class add dev lo parent 1: classid 1:10 htb rate 3mbit
sleep 15

# Severe degradation to 1 Mbps with loss
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 3 (30-45s): Severe - 1 Mbps + 5% loss"
tc qdisc del dev lo root
tc qdisc add dev lo root handle 1: htb default 10
tc class add dev lo parent 1: classid 1:10 htb rate 1mbit
tc qdisc add dev lo parent 1:10 netem loss 5%
sleep 15

# Recover to 5 Mbps
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 4 (45-60s): Recovery - 5 Mbps"
tc qdisc del dev lo root
tc qdisc add dev lo root handle 1: htb default 10
tc class add dev lo parent 1: classid 1:10 htb rate 5mbit
sleep 15

echo ""
echo "Network simulation complete"
EOF

chmod +x /tmp/netem_scenario.sh

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 1: Starting Docker receiver with SRT listener${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Start Docker container with SRT receiver and netem
docker run -d \
    --name srt-receiver \
    --cap-add=NET_ADMIN \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    -v /tmp/netem_scenario.sh:/tmp/netem_scenario.sh \
    srt-navrc-test \
    bash -c "
        echo 'SRT Receiver starting...' && \
        ffmpeg -protocol_whitelist file,udp,srt \
            -i 'srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=${SRT_LATENCY}&enable_stats=1' \
            -c copy \
            -f null - \
            2>&1 | tee /tmp/receiver.log &
        sleep 5 && \
        /tmp/netem_scenario.sh
    "

sleep 5

echo -e "${GREEN}✓ Receiver started${NC}"
echo ""

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 2: Starting FFmpeg sender with visual bitrate overlay${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Start FFmpeg with visual output
# Use drawtext filter to show current bitrate
"${FFMPEG_BIN}" -y \
    -f lavfi -i "testsrc=size=${VIDEO_SIZE}:rate=25:duration=${TEST_DURATION}" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=${TEST_DURATION}" \
    -filter_complex "[0:v]drawtext=\
fontfile=/System/Library/Fonts/Supplemental/Courier New Bold.ttf:\
text='SRT Rate Control Test - ${ENCODER}':\
fontsize=32:fontcolor=white:box=1:boxcolor=black@0.7:\
x=(w-text_w)/2:y=30,\
drawtext=\
fontfile=/System/Library/Fonts/Supplemental/Courier New Bold.ttf:\
text='Target: %{metadata\\\\:lavfi.r128.M}k bps':\
fontsize=28:fontcolor=yellow:box=1:boxcolor=black@0.7:\
x=(w-text_w)/2:y=100,\
drawtext=\
fontfile=/System/Library/Fonts/Supplemental/Courier New Bold.ttf:\
text='Time\\: %{pts\\:gmtime\\:0\\:%H\\\\\\:%M\\\\\\:%S}':\
fontsize=24:fontcolor=cyan:box=1:boxcolor=black@0.7:\
x=(w-text_w)/2:y=h-60[vout]" \
    -map "[vout]" -map 1:a \
    -c:v ${ENCODER} \
    -preset veryfast \
    -tune zerolatency \
    -b:v ${INITIAL_BITRATE} \
    -minrate ${MIN_BITRATE} \
    -maxrate ${MAX_BITRATE} \
    -bufsize 2M \
    -g 50 \
    -sc_threshold 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=${SRT_LATENCY}&enable_stats=1&pkt_size=1316" \
    -c:v copy -c:a copy \
    -f mpegts "${OUTPUT_FILE}" \
    2>&1 | tee sender.log &

FFMPEG_PID=$!

echo -e "${GREEN}✓ Sender started (PID: $FFMPEG_PID)${NC}"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Test running for ${TEST_DURATION} seconds...${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Network simulation phases:"
echo "  • 0-15s:  Good (10 Mbps)"
echo "  • 15-30s: Degraded (3 Mbps)"
echo "  • 30-45s: Severe (1 Mbps + 5% loss)"
echo "  • 45-60s: Recovery (5 Mbps)"
echo ""
echo "Monitoring SRT statistics (Ctrl+C to stop early)..."
echo ""

# Monitor the logs in real-time
tail -f sender.log 2>/dev/null | grep --line-buffered "SRT Stats" &
TAIL_PID=$!

# Wait for test to complete
wait $FFMPEG_PID || true

kill $TAIL_PID 2>/dev/null || true

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Test Complete - Analyzing Results${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Extract statistics
echo -e "${GREEN}SRT Statistics Summary:${NC}"
echo ""

if [ -f sender.log ]; then
    echo "Bandwidth measurements:"
    grep "SRT Stats" sender.log | awk -F'BW=' '{print $2}' | awk '{print "  •", $1}' | tail -10
    echo ""
    
    stats_count=$(grep -c "SRT Stats" sender.log || echo "0")
    echo "  • Total stat updates: $stats_count"
    
    if [ $stats_count -gt 0 ]; then
        avg_loss=$(grep "SRT Stats" sender.log | awk -F'Loss=' '{print $2}' | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print 0}')
        avg_rtt=$(grep "SRT Stats" sender.log | awk -F'RTT=' '{print $2}' | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print 0}')
        echo "  • Average packet loss: ${avg_loss}%"
        echo "  • Average RTT: ${avg_rtt} ms"
    fi
fi

echo ""
echo -e "${GREEN}Output Files:${NC}"
echo "  • Video output: ${OUTPUT_FILE}"
echo "  • Sender log: sender.log"
echo "  • Receiver log: docker logs srt-receiver"
echo ""

# Check receiver logs
echo -e "${GREEN}Receiver Log (last 20 lines):${NC}"
docker logs srt-receiver 2>&1 | grep "SRT Stats" | tail -20 || echo "No stats in receiver log"

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}To play the output with bitrate visualization:${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  ffplay ${OUTPUT_FILE}"
echo ""
echo -e "${GREEN}✅ Test complete!${NC}"

