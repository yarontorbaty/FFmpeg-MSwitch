#!/bin/bash
#
# SRT Rate Control Test with Live VLC Preview
# Shows real-time video with bitrate overlay
#

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ENCODER="${1:-libx264}"
SRT_PORT=4200
UDP_PORT=5000  # For VLC preview

echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  SRT + ${ENCODER} Test with Live VLC Preview${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"

mkdir -p test_results
OUTPUT="test_results/${ENCODER}_live_$(date +%Y%m%d_%H%M%S).ts"

echo -e "${CYAN}Configuration:${NC}"
echo "  • Encoder: ${ENCODER}"
echo "  • SRT Port: ${SRT_PORT}"
echo "  • VLC Preview: udp://localhost:${UDP_PORT}"
echo "  • Output File: ${OUTPUT}"
echo ""

# Cleanup
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker stop srt-test-vlc 2>/dev/null || true
    pkill -f "ffmpeg.*${SRT_PORT}" 2>/dev/null || true
}
trap cleanup EXIT INT

# Check Docker
if ! docker info &> /dev/null; then
    echo -e "${RED}Docker not running${NC}"
    exit 1
fi

# Build Docker image if needed
if ! docker images | grep -q "srt-navrc-test"; then
    echo "Building Docker image..."
    cd /Users/yarontorbaty/Documents/Code/srt
    docker build -t srt-navrc-test -f _test/Dockerfile .
    cd - > /dev/null
fi

echo -e "${GREEN}✓ Docker ready${NC}\n"

# Start Docker receiver with network simulation
echo -e "${BLUE}Starting receiver with network simulation...${NC}\n"

docker run -d --name srt-test-vlc --cap-add=NET_ADMIN \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    srt-navrc-test \
    bash -c '
        set_network() {
            tc qdisc del dev eth0 root 2>/dev/null || true
            tc qdisc add dev eth0 root handle 1: htb default 10
            tc class add dev eth0 parent 1: classid 1:10 htb rate $1
            [ "$2" != "" ] && tc qdisc add dev eth0 parent 1:10 netem loss $2%
            printf "[%s] Network: %s, Loss: %s%%\n" "$(date +%H:%M:%S)" "$1" "${2:-0}"
        }
        
        ffmpeg -hide_banner -v info \
            -protocol_whitelist file,udp,srt \
            -i "srt://0.0.0.0:4200?mode=listener&latency=200&enable_stats=1" \
            -c copy -f null - 2>&1 | grep --line-buffered -E "SRT Stats" &
        
        sleep 8
        printf "\n╔════════════════════════════════════════════╗\n"
        printf "║   Network Simulation (90 seconds)         ║\n"
        printf "╚════════════════════════════════════════════╝\n\n"
        
        printf "Phase 1: Excellent (10 Mbps)\n"
        set_network 10mbit
        sleep 20
        
        printf "\nPhase 2: Good (3 Mbps)\n"
        set_network 3mbit
        sleep 20
        
        printf "\nPhase 3: Poor (1 Mbps + 5%% loss)\n"
        set_network 1mbit 5
        sleep 20
        
        printf "\nPhase 4: Recovery (7 Mbps)\n"
        set_network 7mbit
        sleep 30
        
        printf "\n✅ Simulation complete\n"
        wait
    '

sleep 5
echo -e "${GREEN}✓ Receiver started${NC}\n"

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Starting sender with VLC preview output${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

echo -e "${CYAN}NOW OPEN VLC AND PLAY: ${YELLOW}udp://@:${UDP_PORT}${NC}\n"
echo "  File → Open Network Stream → udp://@:${UDP_PORT}"
echo ""
echo -e "${YELLOW}Press Enter when VLC is ready...${NC}"
read -t 5 || echo "Continuing..."

echo ""
echo -e "${GREEN}✓ Starting stream...${NC}\n"

# Start FFmpeg with visual overlay and dual output (SRT + UDP for VLC)
./ffmpeg -y -re \
    -f lavfi -i "testsrc=size=1280x720:rate=25:duration=90" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=90" \
    -filter_complex "
        [0:v]drawtext=fontsize=48:fontcolor=white:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=50:\
text='${ENCODER} + Enhanced libsrt v1.5.5',\
drawtext=fontsize=36:fontcolor=yellow:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=120:\
text='Bitrate Monitor Test',\
drawtext=fontsize=32:fontcolor=cyan:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=200:\
text='Network Phase\: %{eif\:floor(t/20)+1\:d}/5',\
drawtext=fontsize=28:fontcolor=green:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=280:\
text='Time\: %{pts\:gmtime\:0\:%M\\\\\:%S}',\
drawtext=fontsize=24:fontcolor=white:box=1:boxcolor=blue@0.8:\
x=(w-text_w)/2:y=h-60:\
text='Watch network phases change every 20s'[vout]
    " \
    -map "[vout]" -map 1:a \
    -c:v ${ENCODER} -preset veryfast -tune zerolatency \
    -b:v 5M -minrate 500k -maxrate 10M -bufsize 2M \
    -g 50 -bf 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=200&enable_stats=1" \
    -c:v copy -c:a copy -f mpegts "udp://localhost:${UDP_PORT}" \
    -c:v copy -c:a copy -f mpegts "${OUTPUT}" \
    2>&1 | tee test_results/vlc_test.log | grep --line-buffered -E "frame=|SRT" &

FFMPEG_PID=$!

echo -e "${GREEN}✓ Streaming started (PID: ${FFMPEG_PID})${NC}"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  VLC Preview: ${YELLOW}udp://@:${UDP_PORT}${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "Network will change every 20 seconds:"
echo "  • 0-20s:   10 Mbps (Excellent)"
echo "  • 20-40s:  3 Mbps (Good)"
echo "  • 40-60s:  1 Mbps + 5% loss (Poor)"
echo "  • 60-90s:  7 Mbps (Recovery)"
echo ""
echo -e "${YELLOW}Watch VLC to see the video quality respond to network changes${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop${NC}\n"

wait $FFMPEG_PID 2>/dev/null || true

echo -e "\n${GREEN}✅ Test complete!${NC}\n"

# Show results
echo -e "${CYAN}Docker Network Log:${NC}"
docker logs srt-test-vlc 2>&1 | grep -E "Phase|Network:" | head -10

echo ""
echo -e "${CYAN}Output Files:${NC}"
ls -lh "${OUTPUT}" test_results/vlc_test.log 2>/dev/null || true

echo ""
echo -e "${GREEN}Playback: ./ffplay ${OUTPUT}${NC}\n"

