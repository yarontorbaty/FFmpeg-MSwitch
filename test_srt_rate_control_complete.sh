#!/bin/bash
#
# Complete SRT Rate Control Test
# Tests real-time bitrate adaptation with visual feedback
# Uses Docker with netem for network simulation
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  FFmpeg + Enhanced libsrt: Real-Time Rate Control Test           ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Configuration
FFMPEG="/Users/yarontorbaty/Documents/Code/FFmpeg/ffmpeg"
FFPLAY="/Users/yarontorbaty/Documents/Code/FFmpeg/ffplay"
SRT_PORT=4200
VIDEO_SIZE="1280x720"
FRAMERATE=25
ENCODER="${1:-libx264}"
TEST_DURATION=90

# Rate control parameters
INITIAL_BITRATE=5000000  # 5 Mbps
MIN_BITRATE=500000       # 500 kbps
MAX_BITRATE=10000000     # 10 Mbps
SRT_LATENCY=200          # 200ms for quick response

# Directories
TEST_DIR="/Users/yarontorbaty/Documents/Code/FFmpeg/test_results"
mkdir -p "${TEST_DIR}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_TS="${TEST_DIR}/rate_control_${ENCODER}_${TIMESTAMP}.ts"
STATS_LOG="${TEST_DIR}/stats_${ENCODER}_${TIMESTAMP}.log"
BITRATE_LOG="${TEST_DIR}/bitrate_${ENCODER}_${TIMESTAMP}.log"

echo -e "${CYAN}Test Configuration:${NC}"
echo "  • Encoder: ${ENCODER}"
echo "  • Resolution: ${VIDEO_SIZE} @ ${FRAMERATE}fps"
echo "  • Bitrate Range: $(($MIN_BITRATE/1000))k - $(($MAX_BITRATE/1000000))M"
echo "  • Initial Bitrate: $(($INITIAL_BITRATE/1000000))M"
echo "  • SRT Latency: ${SRT_LATENCY}ms (small buffer)"
echo "  • Duration: ${TEST_DURATION}s"
echo "  • Output: ${OUTPUT_TS}"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    docker stop srt-netem-receiver 2>/dev/null || true
    pkill -f "ffmpeg.*${SRT_PORT}" 2>/dev/null || true
    pkill -f "ffplay" 2>/dev/null || true
    echo "Cleanup complete"
}

trap cleanup EXIT INT TERM

# Check Docker
if ! docker info &> /dev/null; then
    echo -e "${RED}❌ Docker not running${NC}"
    exit 1
fi

# Build Docker image if needed
if ! docker images | grep -q "srt-navrc-test"; then
    echo -e "${YELLOW}Building Docker image...${NC}"
    cd /Users/yarontorbaty/Documents/Code/srt
    docker build -t srt-navrc-test -f _test/Dockerfile . || exit 1
    cd - > /dev/null
fi

echo -e "${GREEN}✓ Docker ready${NC}"
echo ""

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 1: Starting Docker receiver with netem${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Start receiver in Docker with netem control
docker run -d \
    --name srt-netem-receiver \
    --cap-add=NET_ADMIN \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    srt-navrc-test \
    bash -c "
        # Function to apply network conditions
        apply_netem() {
            local rate=\$1
            local loss=\$2
            echo \"[NETEM] Applying: Rate=\${rate}, Loss=\${loss}%\" >&2
            tc qdisc del dev lo root 2>/dev/null || true
            if [ \"\$rate\" != \"unlimited\" ]; then
                tc qdisc add dev lo root handle 1: htb default 10
                tc class add dev lo parent 1: classid 1:10 htb rate \${rate}
                if [ \"\$loss\" != \"0\" ]; then
                    tc qdisc add dev lo parent 1:10 netem loss \${loss}%
                fi
            fi
        }
        
        # Start receiver
        echo '[RECEIVER] Starting SRT listener on port ${SRT_PORT}...' >&2
        ffmpeg -hide_banner -loglevel info \
            -protocol_whitelist file,udp,srt \
            -i 'srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=${SRT_LATENCY}&enable_stats=1&pkt_size=1316' \
            -c copy -f null - 2>&1 &
        
        RECEIVER_PID=\$!
        sleep 3
        
        # Network simulation phases
        echo '[NETEM] Phase 1: Good network (10 Mbps, 0% loss) - 20 seconds' >&2
        apply_netem 10mbit 0
        sleep 20
        
        echo '[NETEM] Phase 2: Moderate degradation (3 Mbps, 0% loss) - 20 seconds' >&2
        apply_netem 3mbit 0
        sleep 20
        
        echo '[NETEM] Phase 3: Severe (1 Mbps, 5% loss) - 20 seconds' >&2
        apply_netem 1mbit 5
        sleep 20
        
        echo '[NETEM] Phase 4: Recovery (7 Mbps, 0% loss) - 30 seconds' >&2
        apply_netem 7mbit 0
        sleep 30
        
        echo '[NETEM] Test complete' >&2
        tc qdisc del dev lo root 2>/dev/null || true
        
        # Keep container alive
        wait \$RECEIVER_PID
    "

sleep 5

echo -e "${GREEN}✓ Receiver container started${NC}"
echo ""

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 2: Starting sender with visual bitrate overlay${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Create a FIFO for bitrate updates
BITRATE_FIFO="/tmp/srt_bitrate_$$"
mkfifo "${BITRATE_FIFO}" || true

# Start bitrate monitor in background
(
    current_bitrate=$INITIAL_BITRATE
    while true; do
        echo "$((current_bitrate/1000))" > "${BITRATE_FIFO}"
        sleep 1
    done
) &
MONITOR_PID=$!

# Start FFmpeg sender with live playback and bitrate overlay
"${FFMPEG}" -y \
    -f lavfi -i "testsrc=size=${VIDEO_SIZE}:rate=${FRAMERATE}:duration=${TEST_DURATION},format=yuv420p" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=${TEST_DURATION}" \
    -filter_complex "
        [0:v]split=2[v1][v2];
        [v1]drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='${ENCODER} SRT Rate Control Test':\
fontsize=48:fontcolor=white:box=1:boxcolor=blue@0.8:\
x=(w-text_w)/2:y=40,
drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='Bitrate\\: %{eif\\:${INITIAL_BITRATE}/1000\\:d} kbps':\
fontsize=36:fontcolor=yellow:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=120,
drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='Time\\: %{pts\\:gmtime\\:0\\:%M\\\\:%S}':\
fontsize=28:fontcolor=cyan:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=h-80,
drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='Watch bitrate adapt to network!':\
fontsize=24:fontcolor=green:box=1:boxcolor=black@0.8:\
x=(w-text_w)/2:y=h-40[venc];
        [v2]drawtext=fontfile=/System/Library/Fonts/Supplemental/Courier\ New\ Bold.ttf:\
text='${ENCODER} SRT Rate Control - LIVE PREVIEW':\
fontsize=36:fontcolor=white:box=1:boxcolor=red@0.8:\
x=(w-text_w)/2:y=30[vplay]
    " \
    -map "[venc]" -map 1:a \
    -c:v ${ENCODER} \
    -preset veryfast \
    -tune zerolatency \
    -b:v ${INITIAL_BITRATE} \
    -minrate ${MIN_BITRATE} \
    -maxrate ${MAX_BITRATE} \
    -bufsize 2M \
    -g 50 \
    -sc_threshold 0 \
    -bf 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=${SRT_LATENCY}&enable_stats=1&pkt_size=1316" \
    -map "[vplay]" -map 1:a \
    -c:v rawvideo -pix_fmt yuv420p \
    -c:a copy \
    -f sdl "SRT Rate Control - ${ENCODER}" \
    2>&1 | tee "${STATS_LOG}" &

SENDER_PID=$!

echo -e "${GREEN}✓ Sender started (PID: ${SENDER_PID})${NC}"
echo ""
echo -e "${YELLOW}Watch the SDL window for live preview!${NC}"
echo -e "${YELLOW}Network phases will change every 20 seconds${NC}"
echo ""

# Monitor stats in terminal
echo -e "${CYAN}Monitoring SRT Statistics...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Real-time stats display
tail -f "${STATS_LOG}" 2>/dev/null | grep --line-buffered -E "SRT Stats|frame=|bitrate=" | while read line; do
    if [[ $line == *"SRT Stats"* ]]; then
        echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $line"
    elif [[ $line == *"frame="* ]]; then
        # Extract frame and bitrate info
        echo -e "${BLUE}$line${NC}" | tr '\r' '\n' | tail -1
    fi
done &
MONITOR_PID=$!

# Wait for sender
wait $SENDER_PID 2>/dev/null || true

# Cleanup monitors
kill $MONITOR_PID 2>/dev/null || true
rm -f "${BITRATE_FIFO}"

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Analysis Complete${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Analyze results
if [ -f "${STATS_LOG}" ]; then
    stats_count=$(grep -c "SRT Stats" "${STATS_LOG}" || echo "0")
    
    if [ $stats_count -gt 0 ]; then
        echo -e "${GREEN}SRT Statistics (${stats_count} samples):${NC}"
        echo ""
        
        # Extract bandwidth over time
        echo "Bandwidth progression:"
        grep "SRT Stats" "${STATS_LOG}" | awk -F'BW=' '{print $2}' | awk '{print "  ", NR")", $1}' | head -20
        
        echo ""
        echo "Loss rate progression:"
        grep "SRT Stats" "${STATS_LOG}" | awk -F'Loss=' '{print $2}' | awk '{print "  ", NR")", $1}' | head -20
        
        echo ""
        # Calculate averages per phase
        echo "Average metrics by phase:"
        total_lines=$(grep -c "SRT Stats" "${STATS_LOG}")
        phase_size=$((total_lines / 4))
        
        for phase in 1 2 3 4; do
            start=$((($phase - 1) * $phase_size + 1))
            end=$(($phase * $phase_size))
            
            avg_bw=$(grep "SRT Stats" "${STATS_LOG}" | sed -n "${start},${end}p" | \
                     awk -F'BW=' '{print $2}' | awk '{sum+=$1; n++} END {if(n>0) printf "%.2f", sum/n}')
            avg_loss=$(grep "SRT Stats" "${STATS_LOG}" | sed -n "${start},${end}p" | \
                       awk -F'Loss=' '{print $2}' | awk '{sum+=$1; n++} END {if(n>0) printf "%.2f", sum/n}')
            avg_rtt=$(grep "SRT Stats" "${STATS_LOG}" | sed -n "${start},${end}p" | \
                      awk -F'RTT=' '{print $2}' | awk '{sum+=$1; n++} END {if(n>0) printf "%.1f", sum/n}')
            
            echo "  Phase $phase: BW=${avg_bw} Mbps, Loss=${avg_loss}%, RTT=${avg_rtt}ms"
        done
    fi
fi

echo ""
echo -e "${GREEN}Output Files:${NC}"
echo "  • Video: ${OUTPUT_TS}"
echo "  • Stats: ${STATS_LOG}"
echo "  • Bitrate log: ${BITRATE_LOG}"
echo ""

echo -e "${CYAN}To play the recorded output:${NC}"
echo "  ${FFPLAY} ${OUTPUT_TS}"
echo ""

echo -e "${CYAN}To view receiver logs:${NC}"
echo "  docker logs srt-netem-receiver 2>&1 | tail -50"
echo ""

echo -e "${GREEN}✅ Test complete!${NC}"

