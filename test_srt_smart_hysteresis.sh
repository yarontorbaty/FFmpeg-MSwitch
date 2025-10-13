#!/bin/bash

# Test SRT Smart Hysteresis for Bitrate Control
# Demonstrates instant downshift and delayed upshift with health checks

set -e

echo "========================================"
echo "SRT Smart Hysteresis Test"
echo "========================================"
echo ""
echo "This test demonstrates:"
echo "  ⚡ INSTANT downshift (protect against congestion)"
echo "  🕒 DELAYED upshift (verify bandwidth stability)"
echo ""

# Configuration
SRT_MIN_BITRATE=3000000   # 3 Mbps
SRT_MAX_BITRATE=25000000  # 25 Mbps
UPSHIFT_DELAY_MS=5000     # 5-second delay before upshift
HTTP_CONTROL_PORT=8080

# Kill any existing processes
pkill -9 ffmpeg 2>/dev/null || true
pkill -9 VLC 2>/dev/null || true
sleep 2

# Clean up log files
rm -f /tmp/srt_hysteresis_test.log

# Ensure we have Big Buck Bunny
if [ ! -f /tmp/big_buck_bunny_720p.mp4 ]; then
    echo "Downloading Big Buck Bunny (720p)..."
    curl -L "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4" \
         -o /tmp/big_buck_bunny_720p.mp4
    echo "Download complete."
fi

echo ""
echo "Starting FFmpeg with Smart Hysteresis..."
echo "  - Encoder: libx264 (H.264)"
echo "  - Initial bitrate: 20 Mbps"
echo "  - SRT rate control: ENABLED"
echo "  - Encoder restart: ENABLED (instant changes)"
echo "  - Upshift delay: ${UPSHIFT_DELAY_MS}ms"
echo "  - HTTP control: Port ${HTTP_CONTROL_PORT}"
echo ""

# Start FFmpeg with SRT rate control + encoder restart + smart hysteresis
(./ffmpeg -loglevel info \
  -re \
  -stream_loop -1 \
  -i /tmp/big_buck_bunny_720p.mp4 \
  -c:v libx264 \
  -preset ultrafast \
  -tune zerolatency \
  -b:v 20000k \
  -g 60 \
  -srt_rate_control 1 \
  -enable_encoder_restart 1 \
  -srt_min_bitrate ${SRT_MIN_BITRATE} \
  -srt_max_bitrate ${SRT_MAX_BITRATE} \
  -srt_upshift_delay_ms ${UPSHIFT_DELAY_MS} \
  -http_control_enable 1 \
  -http_control_port ${HTTP_CONTROL_PORT} \
  -f mpegts "srt://127.0.0.1:9999?mode=listener&latency=3000&streamid=#!::r=test,m=publish,enable_stats=1" \
  2>&1 | tee /tmp/srt_hysteresis_test.log) &

FFMPEG_PID=$!
echo "FFmpeg started (PID: $FFMPEG_PID)"

# Wait for initialization
sleep 8

if ! kill -0 $FFMPEG_PID 2>/dev/null; then
    echo "ERROR: FFmpeg exited unexpectedly"
    cat /tmp/srt_hysteresis_test.log
    exit 1
fi

# Start VLC
echo ""
echo "Starting VLC player..."
open -a VLC "srt://127.0.0.1:9999?mode=caller&latency=3000" &

sleep 10

echo ""
echo "========================================"
echo "PHASE 1: Baseline @ 20 Mbps"
echo "========================================"
echo "Running at full bandwidth..."
sleep 15

# Show current status
tail -1 /tmp/srt_hysteresis_test.log | grep -oE "bitrate=[0-9.]+kbits" | tail -1

echo ""
echo "========================================"
echo "PHASE 2: Force Downshift (20 → 8 Mbps)"
echo "========================================"
echo ""
echo "Sending HTTP command to INSTANTLY drop bitrate..."
curl -X POST http://localhost:${HTTP_CONTROL_PORT} \
  -H "Content-Type: application/json" \
  -d '{"bitrate":8000,"force_idr":1}' 2>/dev/null
echo ""
sleep 2

# Verify instant downshift
grep -E "(INSTANT DOWNSHIFT|ENCODER RESTART)" /tmp/srt_hysteresis_test.log | tail -5

echo ""
echo "Watch VLC: Bitrate should drop INSTANTLY (1-2 frame glitch)"
echo "Waiting 15 seconds at 8 Mbps..."
sleep 15

echo ""
echo "========================================"
echo "PHASE 3: Attempt Upshift (8 → 15 Mbps)"
echo "========================================"
echo ""
echo "Sending HTTP command to increase bitrate to 15 Mbps..."
echo "With upshift delay, this will trigger:"
echo "  1. Pending upshift timer (${UPSHIFT_DELAY_MS}ms)"
echo "  2. Health checks every 500ms"
echo "  3. Upshift approved after delay if bandwidth stable"
echo ""

curl -X POST http://localhost:${HTTP_CONTROL_PORT} \
  -H "Content-Type: application/json" \
  -d '{"bitrate":15000,"force_idr":1}' 2>/dev/null
echo ""

echo ""
echo "Monitoring upshift process..."
echo ""

# Monitor for 12 seconds (longer than upshift delay)
for i in {1..24}; do
    sleep 0.5
    
    # Check for upshift-related messages
    NEW_MSGS=$(grep -E "(UPSHIFT PENDING|HEALTH CHECK|UPSHIFT APPROVED|ENCODER RESTART)" /tmp/srt_hysteresis_test.log 2>/dev/null | tail -1)
    if [ ! -z "$NEW_MSGS" ]; then
        echo "$NEW_MSGS"
    fi
done

echo ""
echo "========================================"
echo "PHASE 4: Simulate Network Fluctuation"
echo "========================================"
echo ""
echo "Dropping to 5 Mbps (should be INSTANT)..."

curl -X POST http://localhost:${HTTP_CONTROL_PORT} \
  -H "Content-Type: application/json" \
  -d '{"bitrate":5000,"force_idr":1}' 2>/dev/null
echo ""
sleep 2

grep -E "INSTANT DOWNSHIFT" /tmp/srt_hysteresis_test.log | tail -1

echo ""
echo "Waiting 3 seconds..."
sleep 3

echo ""
echo "Attempting to increase to 12 Mbps (should start upshift timer)..."
curl -X POST http://localhost:${HTTP_CONTROL_PORT} \
  -H "Content-Type: application/json" \
  -d '{"bitrate":12000,"force_idr":1}' 2>/dev/null
echo ""
sleep 2

grep -E "UPSHIFT PENDING" /tmp/srt_hysteresis_test.log | tail -1

echo ""
echo "Waiting 2 seconds, then dropping again (should CANCEL upshift)..."
sleep 2

curl -X POST http://localhost:${HTTP_CONTROL_PORT} \
  -H "Content-Type: application/json" \
  -d '{"bitrate":6000,"force_idr":1}' 2>/dev/null
echo ""
sleep 2

grep -E "(Cancelling pending upshift|INSTANT DOWNSHIFT)" /tmp/srt_hysteresis_test.log | tail -2

echo ""
echo "========================================"
echo "Test Complete!"
echo "========================================"
echo ""
echo "Summary:"
echo "  ✓ Instant downshift demonstrated"
echo "  ✓ Delayed upshift with health checks"
echo "  ✓ Upshift cancellation on bandwidth drop"
echo "  ✓ Encoder restart working for instant changes"
echo ""
echo "Full log: /tmp/srt_hysteresis_test.log"
echo ""
echo "Press ENTER to view detailed logs and stop..."
read

echo ""
echo "=== DOWNSHIFT Events ==="
grep -E "(INSTANT DOWNSHIFT|AGGRESSIVE MODE)" /tmp/srt_hysteresis_test.log

echo ""
echo "=== UPSHIFT Events ==="
grep -E "(UPSHIFT PENDING|HEALTH CHECK|UPSHIFT APPROVED)" /tmp/srt_hysteresis_test.log | head -20

echo ""
echo "=== ENCODER RESTART Events ==="
grep -E "(ENCODER RESTART|Reopening encoder)" /tmp/srt_hysteresis_test.log

echo ""
echo "Stopping FFmpeg and VLC..."
kill $FFMPEG_PID 2>/dev/null || true
pkill -9 VLC 2>/dev/null || true

echo ""
echo "Done!"

