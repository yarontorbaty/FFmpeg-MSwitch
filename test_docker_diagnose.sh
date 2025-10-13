#!/bin/bash
#
# Diagnostic test - Check if FFmpeg is running inside Docker
#

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        Docker FFmpeg Diagnostic Test                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

cleanup() {
    echo "Cleaning up..."
    docker stop srt-diagnostic 2>/dev/null || true
}
trap cleanup EXIT INT

echo "Starting diagnostic container..."
echo ""

docker run -d --name srt-diagnostic --cap-add=NET_ADMIN \
    ffmpeg-enhanced-srt \
    bash -c '
set -e

echo "=== DIAGNOSTIC START ==="
echo ""
echo "Step 1: Check FFmpeg is available..."
which ffmpeg
ffmpeg -version | head -1
echo ""

echo "Step 2: Check SRT support..."
ffmpeg -protocols 2>&1 | grep srt
echo ""

echo "Step 3: Start receiver..."
ffmpeg -hide_banner -v info \
    -protocol_whitelist file,udp,srt \
    -i "srt://0.0.0.0:4200?mode=listener&latency=100&enable_stats=1" \
    -c copy -f null - \
    > /tmp/receiver.log 2>&1 &
RECEIVER_PID=$!
echo "Receiver PID: $RECEIVER_PID"
sleep 3

echo ""
echo "Step 4: Check if receiver is running..."
if ps -p $RECEIVER_PID > /dev/null; then
    echo "✓ Receiver is running"
    ps aux | grep ffmpeg | grep -v grep
else
    echo "✗ Receiver is NOT running"
    echo "Receiver log:"
    cat /tmp/receiver.log
    exit 1
fi

echo ""
echo "Step 5: Start sender..."
ffmpeg -re \
    -f lavfi -i "testsrc=duration=30:size=640x480:rate=25" \
    -c:v libx264 -preset ultrafast -b:v 2M \
    -f mpegts "srt://127.0.0.1:4200?latency=100&enable_stats=1" \
    > /tmp/sender.log 2>&1 &
SENDER_PID=$!
echo "Sender PID: $SENDER_PID"
sleep 5

echo ""
echo "Step 6: Check if sender is running..."
if ps -p $SENDER_PID > /dev/null; then
    echo "✓ Sender is running"
    ps aux | grep ffmpeg | grep -v grep
else
    echo "✗ Sender is NOT running"
    echo "Sender log:"
    cat /tmp/sender.log
    exit 1
fi

echo ""
echo "Step 7: Check for errors in logs..."
echo "--- Receiver log (last 20 lines) ---"
tail -20 /tmp/receiver.log 2>/dev/null || echo "No receiver log"
echo ""
echo "--- Sender log (last 20 lines) ---"
tail -20 /tmp/sender.log 2>/dev/null || echo "No sender log"

echo ""
echo "Step 8: Monitor for 10 seconds..."
for i in {1..10}; do
    sleep 1
    echo "[$i/10] Checking processes..."
    if ! ps -p $SENDER_PID > /dev/null; then
        echo "Sender died!"
        break
    fi
    if ! ps -p $RECEIVER_PID > /dev/null; then
        echo "Receiver died!"
        break
    fi
done

echo ""
echo "Step 9: Look for SRT Stats..."
echo "--- Sender stats ---"
grep "SRT Stats" /tmp/sender.log 2>/dev/null | tail -5 || echo "No SRT stats in sender"
echo ""
echo "--- Receiver stats ---"
grep "SRT Stats" /tmp/receiver.log 2>/dev/null | tail -5 || echo "No SRT stats in receiver"

echo ""
echo "Step 10: Check frame output..."
echo "--- Sender frames ---"
grep "frame=" /tmp/sender.log 2>/dev/null | tail -3 || echo "No frame info in sender"

echo ""
echo "=== DIAGNOSTIC COMPLETE ==="
echo "Logs saved in /tmp/sender.log and /tmp/receiver.log"

# Keep container alive for inspection
sleep 300
' > /tmp/docker_diagnostic.log 2>&1

sleep 3

echo "Fetching diagnostic output..."
echo ""
docker logs srt-diagnostic 2>&1

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  Diagnostic Summary                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Container is running. To inspect further:"
echo "  docker exec -it srt-diagnostic bash"
echo "  docker logs srt-diagnostic -f"
echo ""
echo "To stop: docker stop srt-diagnostic"

