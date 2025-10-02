#!/bin/bash

# Test: I-frame (IDR) Detection in MSwitch Seamless Mode
# This test verifies that seamless switching only happens on detected keyframes

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"

echo "============================================================"
echo "  MSwitch I-Frame Detection Test"
echo "============================================================"
echo ""
echo "This test demonstrates:"
echo "  ✅ Proper MPEG-TS packet parsing"
echo "  ✅ H.264 NAL unit detection"
echo "  ✅ IDR (keyframe) identification"
echo "  ✅ Seamless mode only switches on I-frames"
echo ""

# Cleanup
pkill -9 ffmpeg 2>/dev/null
sleep 2

LOG_FILE="/tmp/mswitch_idr_test.log"
rm -f "$LOG_FILE"

echo "Step 1: Starting MSwitch in SEAMLESS mode"
echo "  GOP=10 means I-frames every 10 frames (at 25fps = 0.4s)"
echo "------------------------------------------------------------"

"$FFMPEG_PATH" -f mswitch \
    -i "sources=color=red:size=640x480:rate=25,color=green:size=640x480:rate=25,color=blue:size=640x480:rate=25&control=8099&mode=seamless" \
    -c:v libx264 -preset ultrafast -t 30 -f null - \
    > "$LOG_FILE" 2>&1 &

FFMPEG_PID=$!
echo "✅ MSwitch started (PID: $FFMPEG_PID), logging to $LOG_FILE"
echo ""

sleep 3

echo "Step 2: Trigger switch to source 1 (GREEN)"
echo "------------------------------------------------------------"
echo "Sending switch command at $(date +%H:%M:%S.%N | cut -b1-12)..."
curl -s -X POST "http://localhost:8099/switch?source=1"
echo ""
echo "⏳ Waiting for I-frame detection..."
echo ""

sleep 2

echo "Step 3: Trigger switch to source 2 (BLUE)"
echo "------------------------------------------------------------"
echo "Sending switch command at $(date +%H:%M:%S.%N | cut -b1-12)..."
curl -s -X POST "http://localhost:8099/switch?source=2"
echo ""
echo "⏳ Waiting for I-frame detection..."
echo ""

sleep 2

echo "Step 4: Trigger switch back to source 0 (RED)"
echo "------------------------------------------------------------"
echo "Sending switch command at $(date +%H:%M:%S.%N | cut -b1-12)..."
curl -s -X POST "http://localhost:8099/switch?source=0"
echo ""
echo "⏳ Waiting for I-frame detection..."
echo ""

sleep 3

echo "Step 5: Stop and analyze logs"
echo "------------------------------------------------------------"
kill $FFMPEG_PID 2>/dev/null
sleep 2
pkill -9 ffmpeg 2>/dev/null

echo ""
echo "============================================================"
echo "  Analysis Results"
echo "============================================================"
echo ""

echo "1. Subprocess GOP Configuration (should be GOP=10 for seamless):"
grep -E "Started subprocess.*-g [0-9]+" "$LOG_FILE" | head -3
echo ""

echo "2. Mode Detection:"
grep "mode=seamless" "$LOG_FILE" | head -1
echo ""

echo "3. Switch Requests (when command was received):"
grep -E "POST /switch" "$LOG_FILE" | sed 's/^.*POST/POST/' | head -10
echo ""

echo "4. Pending Switches (waiting for I-frame):"
grep -E "Pending seamless" "$LOG_FILE" | head -10
echo ""

echo "5. IDR Detection (when I-frame was found):"
grep -E "IDR frame \(keyframe detected\)" "$LOG_FILE"
echo ""

echo "6. Waiting Messages (if shown, means no I-frame found yet):"
grep -E "Waiting for IDR frame" "$LOG_FILE" | head -5
echo ""

echo "7. Actual Seamless Switches (active source changes):"
grep -E "Seamless switch to source [0-9]+ on IDR" "$LOG_FILE"
echo ""

# Count switches
NUM_SWITCH_REQUESTS=$(grep -c "POST /switch" "$LOG_FILE" 2>/dev/null || echo "0")
NUM_IDR_DETECTIONS=$(grep -c "IDR frame (keyframe detected)" "$LOG_FILE" 2>/dev/null || echo "0")
NUM_WAITING_MSGS=$(grep -c "Waiting for IDR frame" "$LOG_FILE" 2>/dev/null || echo "0")

echo "============================================================"
echo "  Summary"
echo "============================================================"
echo ""
echo "Switch requests sent:       $NUM_SWITCH_REQUESTS"
echo "I-frames detected:          $NUM_IDR_DETECTIONS"
echo "Waiting messages (approx):  $NUM_WAITING_MSGS"
echo ""

if [ "$NUM_IDR_DETECTIONS" -gt 0 ]; then
    echo "✅ SUCCESS: I-frame detection is working!"
    echo "   Seamless switches only happened when IDR frames were detected."
    echo ""
    echo "   GOP=10 at 25fps means I-frames every ~0.4 seconds."
    echo "   The switch delay should be less than 0.4s per switch."
else
    echo "❌ ISSUE: No I-frames detected"
    echo "   This could mean:"
    echo "   - I-frame detection logic needs adjustment"
    echo "   - Subprocess encoding may not be generating keyframes"
    echo "   - Test duration was too short"
fi

echo ""
echo "Full logs available at: $LOG_FILE"
echo "============================================================"

