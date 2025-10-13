#!/bin/bash
# Simple VLC Test - Copy and paste these commands

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Enhanced SRT + VLC Test - Run in 3 terminals           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "TERMINAL 1: Docker Receiver"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
cat << 'CMD1'
docker stop srt-test 2>/dev/null; docker rm srt-test 2>/dev/null
docker run -it --name srt-test --cap-add=NET_ADMIN -p 4200:4200/udp srt-navrc-test bash -c '
ffmpeg -protocol_whitelist file,udp,srt -i "srt://0.0.0.0:4200?mode=listener&latency=200&enable_stats=1" -c copy -f null - 2>&1 | grep "SRT Stats" &
sleep 5
tc qdisc add dev eth0 root handle 1: htb default 10
echo "Phase 1: 10 Mbps (0-30s)"
tc class add dev eth0 parent 1: classid 1:10 htb rate 10mbit
sleep 30
echo "Phase 2: 2 Mbps (30-60s) - WATCH QUALITY DROP"
tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 2mbit
sleep 30
echo "Phase 3: 8 Mbps (60-90s) - RECOVERY"
tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 8mbit
sleep 30
echo "DONE"
wait'
CMD1

echo ""
echo "TERMINAL 2: VLC Player"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
cat << 'CMD2'
/Applications/VLC.app/Contents/MacOS/VLC udp://@:5000
CMD2

echo ""
echo "TERMINAL 3: FFmpeg Stream"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
cat << 'CMD3'
cd /Users/yarontorbaty/Documents/Code/FFmpeg

./ffmpeg -re \
    -f lavfi -i "smptebars=size=1280x720:rate=25:duration=90" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=90" \
    -c:v libx264 -preset veryfast -tune film \
    -b:v 5000k -minrate 500k -maxrate 10000k -bufsize 5000k \
    -g 50 -bf 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:4200?latency=200&enable_stats=1" \
    -f mpegts "udp://localhost:5000?pkt_size=1316"
CMD3

echo ""
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "What you'll see:"
echo "  • SMPTE color bars in VLC (more complex = higher bitrate)"
echo "  • Phase 1 (0-30s):  10 Mbps - should encode ~3-4 Mbps"
echo "  • Phase 2 (30-60s): 2 Mbps - will drop to ~1-1.5 Mbps"
echo "  • Phase 3 (60-90s): 8 Mbps - recovers to ~3-4 Mbps"
echo ""
echo "Check VLC Tools → Media Information → Statistics"
echo "  Watch the 'Input bitrate' change!"
echo ""

