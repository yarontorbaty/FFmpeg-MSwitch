#!/bin/bash
# VLC Test with Strict CBR Mode

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Enhanced SRT + VLC Test with STRICT CBR                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Run these commands in 3 separate terminals:"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TERMINAL 1: Docker Receiver with Network Simulation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
cat << 'CMD1'
docker stop srt-test 2>/dev/null; docker rm srt-test 2>/dev/null

docker run -it --name srt-test --cap-add=NET_ADMIN -p 4200:4200/udp srt-navrc-test bash -c '
ffmpeg -hide_banner -v info -protocol_whitelist file,udp,srt \
    -i "srt://0.0.0.0:4200?mode=listener&latency=200&enable_stats=1" \
    -c copy -f null - 2>&1 | grep --line-buffered "SRT Stats" &

sleep 8
tc qdisc add dev eth0 root handle 1: htb default 10

echo ""
echo "═════════════════════════════════════════"
echo "Phase 1: 10 Mbps (0-30s) - Excellent"
echo "═════════════════════════════════════════"
tc class add dev eth0 parent 1: classid 1:10 htb rate 10mbit
sleep 30

echo ""
echo "═════════════════════════════════════════"
echo "Phase 2: 2 Mbps (30-60s) - DEGRADED"
echo "═════════════════════════════════════════"
tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 2mbit
sleep 30

echo ""
echo "═════════════════════════════════════════"
echo "Phase 3: 8 Mbps (60-90s) - RECOVERY"
echo "═════════════════════════════════════════"
tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 8mbit
sleep 30

echo ""
echo "✅ Network simulation complete"
wait'
CMD1

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TERMINAL 2: VLC Player"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
cat << 'CMD2'
/Applications/VLC.app/Contents/MacOS/VLC udp://@:5000
CMD2

echo ""
echo "Then in VLC:"
echo "  Tools → Media Information → Statistics"
echo "  Watch 'Input bitrate' - should be ~5 Mbps initially"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TERMINAL 3: FFmpeg Encoder (STRICT CBR)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
cat << 'CMD3'
cd /Users/yarontorbaty/Documents/Code/FFmpeg

./ffmpeg -re \
    -f lavfi -i "smptebars=size=1280x720:rate=25:duration=90" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=90" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -x264-params "nal-hrd=cbr:force-cfr=1:bitrate=5000:vbv-maxrate=5000:vbv-bufsize=5000" \
    -g 50 \
    -bf 0 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:4200?latency=200&enable_stats=1" \
    -f mpegts "udp://localhost:5000?pkt_size=1316"
CMD3

echo ""
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "WHAT TO EXPECT:"
echo "  • VLC shows SMPTE color bars"
echo "  • Initial bitrate: ~5 Mbps (5000 kbps)"
echo "  • Phase 1 (0-30s):  Smooth, 5 Mbps"
echo "  • Phase 2 (30-60s): Network limited to 2 Mbps"
echo "  •   → Watch packet loss/buffering in VLC stats"
echo "  •   → Bitrate should drop or buffer fills"
echo "  • Phase 3 (60-90s): Recovery to good quality"
echo ""
echo "IN VLC STATS YOU'LL SEE:"
echo "  • Input bitrate changing"
echo "  • Packet loss during Phase 2"
echo "  • Lost frames/discontinuities"
echo ""
echo "This demonstrates SRT behavior under network constraints!"
echo ""

