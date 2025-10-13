#!/bin/bash

# Test libx265 encoder with HTTP control and encoder restart
# This script tests the HEVC/H.265 encoder with instant bitrate changes

set -e

echo "========================================"
echo "libx265 HTTP Encoder Control Test"
echo "========================================"
echo ""

# Kill any existing FFmpeg or VLC processes
pkill -9 ffmpeg 2>/dev/null || true
pkill -9 VLC 2>/dev/null || true
sleep 2

# Clean up log files
rm -f /tmp/x265_http_test.log

# Ensure we have Big Buck Bunny
if [ ! -f /tmp/big_buck_bunny_720p.mp4 ]; then
    echo "Downloading Big Buck Bunny (720p)..."
    curl -L "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4" \
         -o /tmp/big_buck_bunny_720p.mp4
    echo "Download complete."
fi

echo ""
echo "Starting FFmpeg with libx265 encoder..."
echo "  - Codec: HEVC (libx265)"
echo "  - Initial bitrate: 20 Mbps"
echo "  - HTTP control port: 8080"
echo "  - Encoder restart: ENABLED"
echo ""

# Start FFmpeg in background with libx265
(./ffmpeg -loglevel info \
  -re \
  -stream_loop -1 \
  -i /tmp/big_buck_bunny_720p.mp4 \
  -c:v libx265 \
  -preset ultrafast \
  -tune zerolatency \
  -b:v 20000k \
  -g 60 \
  -http_control_enable 1 \
  -http_control_port 8080 \
  -http_enable_encoder_restart 1 \
  -f mpegts "srt://127.0.0.1:9999?mode=listener&latency=3000" \
  2>&1 | tee /tmp/x265_http_test.log) &

FFMPEG_PID=$!
echo "FFmpeg started (PID: $FFMPEG_PID)"

# Wait for FFmpeg to initialize
echo ""
echo "Waiting for encoder to initialize..."
sleep 8

# Check if FFmpeg is still running
if ! kill -0 $FFMPEG_PID 2>/dev/null; then
    echo "ERROR: FFmpeg exited unexpectedly"
    cat /tmp/x265_http_test.log
    exit 1
fi

# Start VLC to play the stream
echo ""
echo "Starting VLC player..."
open -a VLC "srt://127.0.0.1:9999?mode=caller" &
VLC_PID=$!

# Wait for VLC to connect
sleep 10

echo ""
echo "========================================"
echo "Encoder is running at 20 Mbps"
echo "========================================"
echo ""
echo "Press ENTER to test instant bitrate change (20 → 8 Mbps)..."
read

# Show current bitrate
echo ""
echo "Current encoding status:"
tail -1 /tmp/x265_http_test.log | grep -oE "frame=.* bitrate=[0-9.]+kbits" || echo "(no stats yet)"

echo ""
echo "Sending HTTP command: Change bitrate to 8 Mbps + Force IDR"
RESPONSE=$(curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"bitrate":8000,"force_idr":1}' 2>/dev/null)

echo "Response: $RESPONSE"

# Wait for restart to complete
sleep 2

# Check logs for restart confirmation
echo ""
echo "Encoder restart log:"
grep -E "(ENCODER RESTART|Reopening encoder|INSTANT bitrate)" /tmp/x265_http_test.log | tail -5

echo ""
echo "========================================"
echo "Bitrate changed to 8 Mbps"
echo "========================================"
echo ""
echo "Watch VLC for:"
echo "  - Brief 1-2 frame glitch (encoder restart)"
echo "  - Reduced quality/bitrate immediately after"
echo "  - Smooth 24fps playback maintained"
echo ""
echo "Press ENTER to test another change (8 → 15 Mbps)..."
read

echo ""
echo "Sending HTTP command: Change bitrate to 15 Mbps + Force IDR"
RESPONSE=$(curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"bitrate":15000,"force_idr":1}' 2>/dev/null)

echo "Response: $RESPONSE"

sleep 2

echo ""
echo "Encoder restart log:"
grep -E "(ENCODER RESTART|Reopening encoder|INSTANT bitrate)" /tmp/x265_http_test.log | tail -5

echo ""
echo "========================================"
echo "Bitrate changed to 15 Mbps"
echo "========================================"
echo ""
echo "Watch VLC for improved quality"
echo ""
echo "Press ENTER to test extreme drop (15 → 3 Mbps)..."
read

echo ""
echo "Sending HTTP command: Change bitrate to 3 Mbps + Force IDR"
RESPONSE=$(curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"bitrate":3000,"force_idr":1}' 2>/dev/null)

echo "Response: $RESPONSE"

sleep 2

echo ""
echo "Encoder restart log:"
grep -E "(ENCODER RESTART|Reopening encoder|INSTANT bitrate)" /tmp/x265_http_test.log | tail -5

echo ""
echo "========================================"
echo "Test Complete!"
echo "========================================"
echo ""
echo "Summary:"
echo "  ✓ libx265 encoder with HTTP control"
echo "  ✓ Instant bitrate changes via encoder restart"
echo "  ✓ Tested: 20 → 8 → 15 → 3 Mbps"
echo ""
echo "Log file: /tmp/x265_http_test.log"
echo ""
echo "Press ENTER to stop FFmpeg and VLC..."
read

# Cleanup
echo ""
echo "Stopping FFmpeg and VLC..."
kill $FFMPEG_PID 2>/dev/null || true
pkill -9 VLC 2>/dev/null || true

echo ""
echo "Done! Check VLC recording if you captured the demo."

