#!/bin/bash
#
# Simple SRT to VLC Live Preview
# No complex overlays, just streaming
#

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ENCODER="${1:-libx264}"
SRT_PORT=4200
UDP_PORT=5000

echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Live VLC Preview: ${ENCODER} + Enhanced SRT${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}\n"

mkdir -p test_results
OUTPUT="test_results/${ENCODER}_vlc_$(date +%H%M%S).ts"

# Cleanup
cleanup() {
    echo -e "\n${YELLOW}Stopping...${NC}"
    docker stop srt-vlc 2>/dev/null || true
    pkill -f "ffmpeg.*${SRT_PORT}" 2>/dev/null || true
}
trap cleanup EXIT INT

# Start Docker receiver with netem
echo -e "${CYAN}Starting receiver with network simulation...${NC}\n"

docker run -d --name srt-vlc --cap-add=NET_ADMIN \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    srt-navrc-test \
    bash -c '
        tc qdisc add dev eth0 root handle 1: htb default 10
        tc class add dev eth0 parent 1: classid 1:10 htb rate 10mbit
        
        ffmpeg -hide_banner -v info \
            -protocol_whitelist file,udp,srt \
            -i "srt://0.0.0.0:4200?mode=listener&latency=200&enable_stats=1" \
            -c copy -f null - 2>&1 | grep --line-buffered "SRT Stats" &
        
        sleep 8
        echo "[$(date +%H:%M:%S)] Phase 1: 10 Mbps"
        sleep 20
        
        tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 3mbit
        echo "[$(date +%H:%M:%S)] Phase 2: 3 Mbps"
        sleep 20
        
        tc qdisc del dev eth0 root
        tc qdisc add dev eth0 root handle 1: htb default 10
        tc class add dev eth0 parent 1: classid 1:10 htb rate 1mbit
        tc qdisc add dev eth0 parent 1:10 netem loss 5%
        echo "[$(date +%H:%M:%S)] Phase 3: 1 Mbps + 5% loss"
        sleep 20
        
        tc qdisc del dev eth0 root
        tc qdisc add dev eth0 root handle 1: htb default 10
        tc class add dev eth0 parent 1: classid 1:10 htb rate 7mbit
        echo "[$(date +%H:%M:%S)] Phase 4: 7 Mbps"
        sleep 30
        
        echo "[$(date +%H:%M:%S)] Complete"
        wait
    '

sleep 3

echo -e "${GREEN}✓ Receiver started${NC}\n"

echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                  OPEN VLC NOW                             ║${NC}"
echo -e "${CYAN}╠═══════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║  File → Open Network Stream → ${YELLOW}udp://@:5000${CYAN}              ║${NC}"
echo -e "${CYAN}║                                                           ║${NC}"
echo -e "${CYAN}║  Or run: ${YELLOW}/Applications/VLC.app/Contents/MacOS/VLC \\${CYAN}   ║${NC}"
echo -e "${CYAN}║          ${YELLOW}udp://@:5000${CYAN}                                    ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}\n"

echo -e "Starting stream in 3 seconds...\n"
sleep 3

echo -e "${GREEN}✓ Streaming now!${NC}\n"

# Stream with simple overlay
./ffmpeg -y -re \
    -f lavfi -i "testsrc=size=1280x720:rate=25:duration=90" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=90" \
    -vf "drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='${ENCODER} + SRT Test - Phase %{eif\:floor(t/20)+1\:d}/5':fontsize=40:fontcolor=white:box=1:boxcolor=black@0.7:x=(w-text_w)/2:y=50" \
    -c:v ${ENCODER} -preset veryfast -tune zerolatency \
    -b:v 5M -minrate 500k -maxrate 10M -bufsize 2M \
    -g 50 -bf 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=200&enable_stats=1" \
    -c:v copy -c:a copy -f mpegts "udp://localhost:${UDP_PORT}?pkt_size=1316" \
    -c:v copy -c:a copy -f mpegts "${OUTPUT}" \
    2>&1 | tee test_results/vlc_stream.log | grep --line-buffered -E "frame=|SRT Stats" &

FFMPEG_PID=$!

echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "  ${YELLOW}VLC Preview: udp://@:5000${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"
echo "Network phases (90 seconds total):"
echo "  • 0-20s:   ${GREEN}10 Mbps${NC} - Excellent quality"
echo "  • 20-40s:  ${YELLOW}3 Mbps${NC} - Good quality"
echo "  • 40-60s:  ${RED}1 Mbps + 5% loss${NC} - Poor (watch for artifacts)"
echo "  • 60-90s:  ${GREEN}7 Mbps${NC} - Recovery"
echo ""
echo -e "${YELLOW}Watch VLC - you should see test pattern with phase counter${NC}"
echo -e "${CYAN}Monitoring...${NC}\n"

# Monitor  
tail -f test_results/vlc_stream.log 2>/dev/null | grep --line-buffered "SRT Stats" | while read line; do
    echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $line"
done &
TAIL_PID=$!

wait $FFMPEG_PID 2>/dev/null || true
sleep 1
kill $TAIL_PID 2>/dev/null || true

echo -e "\n${GREEN}✅ Stream complete!${NC}\n"

echo "Docker phases:"
docker logs srt-vlc 2>&1 | grep "Phase"

echo ""
echo "Output: ${OUTPUT}"
echo "Playback: ./ffplay ${OUTPUT}"
echo ""

