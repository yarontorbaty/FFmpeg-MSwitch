#!/bin/bash

# Test SRT Rate Control WITHOUT network emulation
# This will help isolate if artifacting is from local issues vs network stress

set -e

SRT_PORT=5556
VLC_PORT=5402

# Get host IP for VLC
if [[ "$OSTYPE" == "darwin"* ]]; then
    HOST_IP=$(ifconfig | grep -E "inet.*broadcast" | awk '{print $2}' | head -1)
else
    HOST_IP=$(hostname -I | awk '{print $1}')
fi

echo "Host IP: $HOST_IP"

echo "[1/3] Preparing Big Buck Bunny video..."
if [ ! -f "/tmp/big_buck_bunny_720p.mp4" ]; then
    echo "Downloading Big Buck Bunny..."
    curl -L -o /tmp/big_buck_bunny_720p.mp4 "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
    
    # Verify download
    if [ ! -s "/tmp/big_buck_bunny_720p.mp4" ]; then
        echo "❌ Download failed or file is empty"
        exit 1
    fi
    echo "   ✓ Downloaded successfully"
else
    echo "   ✓ Already cached"
fi

echo "[2/3] Opening VLC for playback..."
# Kill any existing VLC
pkill -f "vlc.*udp" || true
sleep 2

# Start VLC
/Applications/VLC.app/Contents/MacOS/VLC "udp://@:$VLC_PORT" --intf dummy --play-and-exit &
VLC_PID=$!
sleep 3

# Check if VLC is running
if ! kill -0 $VLC_PID 2>/dev/null; then
    echo "❌ VLC failed to start"
    exit 1
fi
echo "   ✓ VLC ready on port $VLC_PORT"

echo "[3/3] Starting Docker with SRT Rate Control (NO NETWORK STRESS)..."

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📺  WATCH VLC - Should see smooth video with minimal artifacts"
echo "  🚫  NO NETWORK STRESS - Testing local performance only"
echo ""
echo "  Expected: Smooth video, stable bitrate around 4-5 Mbps"
echo "  Duration: 60 seconds"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Clean up any existing containers
docker stop srt-no-stress-test 2>/dev/null || true
docker rm srt-no-stress-test 2>/dev/null || true

# Run Docker container with SRT sender/receiver (NO network emulation)
docker run --name srt-no-stress-test --rm -d \
    -p $SRT_PORT:$SRT_PORT/udp \
    -p $VLC_PORT:$VLC_PORT/udp \
    -v /tmp:/tmp \
    ffmpeg-srt-x264tcp \
    bash -c "
        echo 'Starting receiver (SRT → UDP to VLC)...'
        ffmpeg -hide_banner -loglevel info \
            -protocol_whitelist file,udp,srt \
            -i \"srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=3000&rcvbuf=10000000&sndbuf=10000000&enable_stats=1\" \
            -c copy \
            -f mpegts \"udp://${HOST_IP}:${VLC_PORT}?pkt_size=1316\" \
            2>&1 | grep --line-buffered \"SRT Stats\" &
        RX_PID=\$!
        sleep 3

        echo 'Starting sender with SRT Rate Control (NO NETWORK STRESS)...'
        echo '   (Min: 500 kbps, Max: 5000 kbps)'

        # Send Big Buck Bunny with rate control but NO network emulation
        ffmpeg -re -stream_loop -1 \
            -i /tmp/big_buck_bunny_720p.mp4 \
            -vf \"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:fontsize=32:fontcolor=white:box=1:boxcolor=black@0.7:boxborderw=10:x=20:y=20:text='SRT Rate Control - NO NETWORK STRESS':enable=1,
                 drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=green@0.8:boxborderw=8:x=20:y=80:text='Testing local performance - should be smooth':enable='between(t,0,30)',
                 drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:fontsize=24:fontcolor=white:box=1:boxcolor=blue@0.8:boxborderw=8:x=20:y=80:text='No network emulation - stable conditions':enable='gte(t,30)'\" \
            -c:v libx264 -preset veryfast -tune zerolatency \
            -b:v 4000k -maxrate 5000k -bufsize 20000k \
            -g 50 -sc_threshold 0 \
            -srt_rate_control 1 \
            -srt_min_bitrate 500000 \
            -srt_max_bitrate 5000000 \
            -c:a aac -b:a 128k \
            -f mpegts \"srt://127.0.0.1:${SRT_PORT}?latency=3000&rcvbuf=10000000&sndbuf=10000000&enable_stats=1\" \
            2>&1 | tee /tmp/sender_no_stress.log &
        TX_PID=\$!

        sleep 3
        echo '   ✓ FFmpeg sender started'

        echo ''
        echo '🎬 Demo running for 60 seconds...'
        echo '📺 Watch VLC for video quality'
        echo '📊 Check logs for rate control messages'

        # Run for 60 seconds
        sleep 60

        echo ''
        echo '🏁 Demo complete!'
        echo '📋 Checking results...'

        # Show rate control summary
        echo ''
        echo '📊 Rate Control Summary:'
        grep 'SRT Rate Control' /tmp/sender_no_stress.log | tail -10

        # Clean up
        kill \$TX_PID \$RX_PID 2>/dev/null || true
        echo '✓ Cleanup complete'
    "

# Wait for demo to complete
echo ""
echo "⏳ Waiting for demo to complete..."
wait

# Clean up
docker stop srt-no-stress-test 2>/dev/null || true
pkill -f "vlc.*udp" 2>/dev/null || true

echo ""
echo "✅ Test complete!"
echo ""
echo "📋 Results:"
echo "  - Check VLC playback quality (should be smooth)"
echo "  - Check /tmp/sender_no_stress.log for rate control messages"
echo ""
echo "🔍 Analysis:"
echo "  - If video was smooth: Issue is with network emulation"
echo "  - If video had artifacts: Issue is with local SRT/encoding"
