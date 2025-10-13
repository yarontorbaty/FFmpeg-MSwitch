#!/bin/bash

# SRT Smart Hysteresis Demo - Local with pfctl/dnctl
# Uses macOS packet filter for bandwidth control

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   SRT SMART HYSTERESIS DEMO (Local with pfctl)              ║"
echo "║   Dynamic Bitrate Control + Real Network Limits             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "⚠️  This script requires sudo access for pfctl/dnctl"
echo "Please enter your password when prompted..."
echo ""

# Request sudo access upfront and keep it alive
sudo -v
echo "✓ Sudo access granted"
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# Configuration
SRT_PORT=9999
PHASE_1_DURATION=25
PHASE_2_DURATION=25
PHASE_3_DURATION=25
PHASE_4_DURATION=25
UPSHIFT_DELAY_MS=5000

echo "✓ Configuration loaded"

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    sudo pfctl -d 2>/dev/null || true
    sudo dnctl -q flush 2>/dev/null || true
    pkill -9 VLC 2>/dev/null || true
    pkill -9 ffmpeg 2>/dev/null || true
    pkill -9 python3 2>/dev/null || true
    echo "✓ Cleanup complete"
}

trap cleanup EXIT

echo "✓ Cleanup handler registered"
echo ""

# Check if Big Buck Bunny exists
if [ ! -f "/tmp/big_buck_bunny_720p.mp4" ]; then
    echo "Downloading Big Buck Bunny (720p)..."
    curl -L "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4" \
         -o /tmp/big_buck_bunny_720p.mp4
    echo "✓ Download complete"
else
    echo "✓ Big Buck Bunny already downloaded"
fi

# Clean up any existing rules
echo "Cleaning up any existing pfctl/dnctl rules..."
sudo pfctl -d 2>/dev/null || true
sudo dnctl -q flush 2>/dev/null || true
echo "✓ Existing rules cleaned"

echo ""
echo "Starting FFmpeg with SRT rate control and visual overlay..."
echo "(This may take a few seconds...)"

# Start FFmpeg with SRT rate control
./ffmpeg -loglevel info \
  -re -stream_loop -1 -i /tmp/big_buck_bunny_720p.mp4 \
  -vf "drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:fontsize=40:fontcolor=white:box=1:boxcolor=black@0.8:boxborderw=12:x=30:y=30:text='SRT Smart Hysteresis Demo':enable=1,
       drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:fontsize=28:fontcolor=white:box=1:boxcolor=green@0.85:boxborderw=10:x=30:y=100:text='PHASE 1 | Network\: Excellent (30 Mbps) | Target\: ~20 Mbps':enable='between(t,0,${PHASE_1_DURATION})',
       drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:fontsize=28:fontcolor=white:box=1:boxcolor=red@0.85:boxborderw=10:x=30:y=100:text='PHASE 2 | Network\: CONGESTION (8 Mbps + loss) | Target\: ~6 Mbps':enable='between(t,${PHASE_1_DURATION},$((PHASE_1_DURATION + PHASE_2_DURATION)))',
       drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:fontsize=28:fontcolor=white:box=1:boxcolor=orange@0.85:boxborderw=10:x=30:y=100:text='PHASE 3 | Network\: Recovery (15 Mbps) | Target\: ~12 Mbps (delayed)':enable='between(t,$((PHASE_1_DURATION + PHASE_2_DURATION)),$((PHASE_1_DURATION + PHASE_2_DURATION + PHASE_3_DURATION)))',
       drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:fontsize=28:fontcolor=white:box=1:boxcolor=yellow@0.85:boxborderw=10:x=30:y=100:text='PHASE 4 | Network\: Fluctuation (6 Mbps) | Upshift Cancelled':enable='gte(t,$((PHASE_1_DURATION + PHASE_2_DURATION + PHASE_3_DURATION)))'" \
  -c:v libx264 \
  -preset ultrafast \
  -tune zerolatency \
  -b:v 10000k \
  -g 60 \
  -srt_rate_control 1 \
  -srt_disable_auto_adjust 0 \
  -enable_encoder_restart 1 \
  -srt_min_bitrate 3000000 \
  -srt_max_bitrate 25000000 \
  -srt_upshift_delay_ms ${UPSHIFT_DELAY_MS} \
  -c:a aac -b:a 128k \
  -f mpegts "srt://127.0.0.1:${SRT_PORT}?mode=listener&transtype=live&latency=500&rcvbuf=10485760&sndbuf=10485760&enable_stats=1" \
  2>&1 | tee /tmp/demo_sender.log &
FFMPEG_PID=$!

echo "✓ FFmpeg started with PID: $FFMPEG_PID"
echo "Waiting for FFmpeg to initialize..."
sleep 5
echo "✓ FFmpeg should be ready"

echo ""
echo "Starting VLC player (SRT caller)..."
open -a VLC "srt://127.0.0.1:${SRT_PORT}?mode=caller&transtype=live&latency=500" &
sleep 5

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    STARTING DEMO                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "📺  Watch VLC - On-screen overlay shows network phase"
echo "📊  Graph will appear in new terminal window showing:"
echo "     • Actual bitrate (from encoder)"
echo "     • Target bitrate (from SRT bandwidth estimation)"
echo "     • Packet loss percentage"
echo ""

# Start plotting in a new terminal window
osascript -e 'tell application "Terminal" to do script "cd '"$(pwd)"' && python3 plot_hysteresis.py"' &

sleep 2

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "PHASE 1: Baseline (30 Mbps, ${PHASE_1_DURATION}s)"
echo "════════════════════════════════════════════════════════════════"
echo "SRT will automatically adjust to available bandwidth..."

# Phase 1: High bandwidth (30 Mbps)
sudo pfctl -e
sudo dnctl pipe 1 config bw 30Mbit/s
cat <<EOF | sudo pfctl -f -
dummynet in proto udp from any to any port ${SRT_PORT} pipe 1
dummynet out proto udp from any to any port ${SRT_PORT} pipe 1
EOF

sleep ${PHASE_1_DURATION}

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "PHASE 2: Bandwidth Drop (8 Mbps, ${PHASE_2_DURATION}s)"
echo "════════════════════════════════════════════════════════════════"
echo "⚡ INSTANT DOWNSHIFT should occur automatically..."

# Drop to 8 Mbps
sudo dnctl pipe 1 config bw 8Mbit/s

sleep ${PHASE_2_DURATION}

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "PHASE 3: Bandwidth Recovery (15 Mbps, ${PHASE_3_DURATION}s)"
echo "════════════════════════════════════════════════════════════════"
echo "🕒 DELAYED UPSHIFT with health checks (${UPSHIFT_DELAY_MS}ms delay)..."

# Increase to 15 Mbps
sudo dnctl pipe 1 config bw 15Mbit/s

sleep ${PHASE_3_DURATION}

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "PHASE 4: Upshift Cancellation (${PHASE_4_DURATION}s)"
echo "════════════════════════════════════════════════════════════════"
echo "✗ Upshift should be CANCELLED automatically..."

# Drop to 6 Mbps to trigger cancellation
sudo dnctl pipe 1 config bw 6Mbit/s

sleep ${PHASE_4_DURATION}

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    DEMO COMPLETE!                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# Cleanup
cleanup
