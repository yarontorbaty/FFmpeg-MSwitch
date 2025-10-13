#!/bin/bash
#
# VLC Test with Working Text Overlay
#

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

UDP_PORT=5000
SRT_PORT=4200
FONT="/System/Library/Fonts/Supplemental/Arial.ttf"

# Check if font exists, otherwise use fallback
if [ ! -f "$FONT" ]; then
    FONT="/System/Library/Fonts/Helvetica.ttc"
fi

echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  VLC Live: Enhanced SRT + Bitrate Overlay            ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}\n"

mkdir -p test_results

# Cleanup
cleanup() {
    echo -e "\n${YELLOW}Stopping...${NC}"
    docker stop srt-overlay 2>/dev/null || true
    pkill -f "ffmpeg.*${SRT_PORT}" 2>/dev/null || true
}
trap cleanup EXIT INT

# Start receiver
echo -e "${CYAN}Starting SRT receiver with network simulation...${NC}\n"

docker run -d --name srt-overlay --cap-add=NET_ADMIN \
    -p ${SRT_PORT}:${SRT_PORT}/udp \
    srt-navrc-test \
    bash -c '
        ffmpeg -hide_banner -v info \
            -protocol_whitelist file,udp,srt \
            -i "srt://0.0.0.0:4200?mode=listener&latency=200&enable_stats=1" \
            -c copy -f null - 2>&1 | grep --line-buffered "SRT Stats" &
        
        sleep 8
        tc qdisc add dev eth0 root handle 1: htb default 10
        
        echo "Phase 1: 10 Mbps (30s)"
        tc class add dev eth0 parent 1: classid 1:10 htb rate 10mbit
        sleep 30
        
        echo "Phase 2: 2 Mbps (30s) - Watch quality!"
        tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 2mbit
        sleep 30
        
        echo "Phase 3: 8 Mbps (30s) - Recovery"
        tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 8mbit
        sleep 30
        
        echo "Complete"
        wait
    '

sleep 3
echo -e "${GREEN}✓ Receiver ready${NC}\n"

# Open VLC
echo -e "${CYAN}Opening VLC...${NC}\n"

if [ -f /Applications/VLC.app/Contents/MacOS/VLC ]; then
    /Applications/VLC.app/Contents/MacOS/VLC udp://@:${UDP_PORT} > /dev/null 2>&1 &
    sleep 2
    echo -e "${GREEN}✓ VLC should be open now${NC}"
else
    echo -e "${YELLOW}Open VLC: File → Network → udp://@:${UDP_PORT}${NC}"
fi

echo ""
echo -e "${CYAN}Starting stream with overlay...${NC}\n"
sleep 1

# Stream with text overlay
./ffmpeg -re -v warning -stats \
    -f lavfi -i "testsrc=size=1280x720:rate=25:duration=90,format=yuv420p" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=90" \
    -vf "drawtext=fontfile=${FONT}:text='libx264 + Enhanced SRT v1.5.5':fontsize=44:fontcolor=white:box=1:boxcolor=blue@0.8:x=(w-text_w)/2:y=40,drawtext=fontfile=${FONT}:text='Target Bitrate\: 5 Mbps':fontsize=36:fontcolor=yellow:box=1:boxcolor=black@0.8:x=(w-text_w)/2:y=120,drawtext=fontfile=${FONT}:text='Time\: %{pts\:hms}':fontsize=32:fontcolor=cyan:box=1:boxcolor=black@0.8:x=(w-text_w)/2:y=h-80" \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -b:v 5M -minrate 500k -maxrate 10M -bufsize 1M \
    -g 50 -bf 0 -sc_threshold 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:${SRT_PORT}?latency=200&enable_stats=1" \
    -f mpegts "udp://localhost:${UDP_PORT}?pkt_size=1316" \
    2>&1 | tee test_results/vlc_overlay.log

echo -e "\n${GREEN}✅ Complete!${NC}\n"

echo "Phases from Docker:"
docker logs srt-overlay 2>&1 | grep "Phase"

echo -e "\n${CYAN}You should have seen in VLC:${NC}"
echo "  • Title: 'libx264 + Enhanced SRT v1.5.5'"
echo "  • Bitrate info"
echo "  • Time counter"
echo "  • Quality changes during Phase 2 (2 Mbps)"
echo ""

