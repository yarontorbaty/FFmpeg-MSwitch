#!/bin/bash

# Test: I-frame Detection with Real-time Playback
# Uses ffplay to force real-time processing and enable visual switching observation

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
FFPLAY_PATH="${FFPLAY_PATH:-./ffplay}"

echo "============================================================"
echo "  MSwitch I-Frame Detection - Real-time Test"
echo "============================================================"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 2

LOG_FILE="/tmp/mswitch_idr_realtime.log"
rm -f "$LOG_FILE"

echo "Starting MSwitch with ffplay output (real-time processing)..."
echo "This will show visual output while we test switching."
echo ""

"$FFMPEG_PATH" -f mswitch \
    -i "sources=color=red:size=640x480:rate=25,color=green:size=640x480:rate=25,color=blue:size=640x480:rate=25&control=8099&mode=seamless" \
    -c:v libx264 -preset ultrafast -f mpegts - \
    2> "$LOG_FILE" | "$FFPLAY_PATH" -i - -loglevel quiet &

FFMPEG_PID=$!
echo "✅ MSwitch + ffplay started (PID: $FFMPEG_PID)"
echo ""

sleep 4

echo "Waiting for HTTP server to be ready..."
for i in {1..10}; do
    if curl -s http://localhost:8099/status > /dev/null 2>&1; then
        echo "✅ Control API is responding"
        break
    fi
    echo "  Attempt $i/10..."
    sleep 1
done
echo ""

echo "Current status:"
curl -s http://localhost:8099/status
echo ""
echo ""

echo "============================================================"
echo "  Sending Switch Commands"
echo "============================================================"
echo ""

echo "[$(date +%H:%M:%S)] Switching to source 1 (GREEN)..."
curl -s -X POST "http://localhost:8099/switch?source=1"
echo ""
sleep 3

echo "[$(date +%H:%M:%S)] Switching to source 2 (BLUE)..."
curl -s -X POST "http://localhost:8099/switch?source=2"
echo ""
sleep 3

echo "[$(date +%H:%M:%S)] Switching back to source 0 (RED)..."
curl -s -X POST "http://localhost:8099/switch?source=0"
echo ""
sleep 3

echo "[$(date +%H:%M:%S)] Rapid switching test (GREEN -> BLUE -> RED)..."
curl -s -X POST "http://localhost:8099/switch?source=1"
echo -n " -> "
sleep 1
curl -s -X POST "http://localhost:8099/switch?source=2"
echo -n " -> "
sleep 1
curl -s -X POST "http://localhost:8099/switch?source=0"
echo ""
echo ""

sleep 3

echo "============================================================"
echo "  Stopping and Analyzing"
echo "============================================================"
kill $FFMPEG_PID 2>/dev/null
sleep 2
pkill -9 ffmpeg ffplay 2>/dev/null

echo ""
echo "1. Control Server Activity:"
grep -E "Control (server|request)" "$LOG_FILE" | head -10
echo ""

echo "2. Switch Requests Received:"
grep -E "POST /switch" "$LOG_FILE"
echo ""

echo "3. Pending Seamless Switches:"
grep -E "Pending seamless" "$LOG_FILE"
echo ""

echo "4. IDR Frame Detections:"
grep -E "IDR frame.*keyframe detected" "$LOG_FILE"
echo ""

echo "5. Waiting for Keyframe Messages:"
grep -E "Waiting for IDR" "$LOG_FILE" | head -5
echo ""

echo "6. Actual Switches:"
grep -E "Seamless switch to source" "$LOG_FILE"
echo ""

# Statistics
NUM_REQUESTS=$(grep -c "POST /switch" "$LOG_FILE" 2>/dev/null || echo "0")
NUM_PENDING=$(grep -c "Pending seamless" "$LOG_FILE" 2>/dev/null || echo "0")
NUM_IDR=$(grep -c "IDR frame.*keyframe detected" "$LOG_FILE" 2>/dev/null || echo "0")
NUM_WAITING=$(grep -c "Waiting for IDR" "$LOG_FILE" 2>/dev/null || echo "0")

echo "============================================================"
echo "  Statistics"
echo "============================================================"
echo "HTTP switch requests:       $NUM_REQUESTS"
echo "Pending switch commands:    $NUM_PENDING"
echo "IDR frames detected:        $NUM_IDR"
echo "Waiting messages:           $NUM_WAITING"
echo ""

if [ "$NUM_IDR" -gt 0 ]; then
    echo "✅ SUCCESS: I-frame detection is working!"
    echo "   Seamless mode waited for IDR frames before switching."
    AVG_WAIT=$(echo "scale=2; $NUM_WAITING / $NUM_PENDING" | bc 2>/dev/null || echo "N/A")
    echo "   Average wait cycles per switch: $AVG_WAIT"
else
    if [ "$NUM_PENDING" -eq 0 ]; then
        echo "⚠️  No switch requests were processed by the control server"
        echo "   Check if the control server is accepting connections"
    else
        echo "⚠️  Switch requests were received but no IDR frames detected"
        echo "   The I-frame detection logic may need adjustment"
    fi
fi

echo ""
echo "Full logs: $LOG_FILE"
echo "============================================================"

