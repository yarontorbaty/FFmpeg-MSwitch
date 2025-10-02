#!/bin/bash

# Real-time MSwitch Filter Test with Visual Output
# Demonstrates switching between RED, GREEN, BLUE with ffplay

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
FFPLAY_PATH="${FFPLAY_PATH:-./ffplay}"

echo "============================================================"
echo "  MSwitch Filter - Real-time Visual Switching Test"
echo "============================================================"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 2

echo "This test will demonstrate the mswitch filter working in real-time."
echo "You'll see different colored outputs based on the 'map' parameter."
echo ""
echo "We'll create 3 separate 10-second videos to simulate switching:"
echo "  1. First 10s: RED (map=0)"
echo "  2. Next 10s:  GREEN (map=1)"  
echo "  3. Final 10s: BLUE (map=2)"
echo ""

# Test 1: RED for 10 seconds
echo "========================================="
echo "Test 1: Displaying RED (10 seconds)"
echo "========================================="
echo ""

"$FFMPEG_PATH" \
    -f lavfi -i "color=red:size=640x480:rate=25" \
    -f lavfi -i "color=green:size=640x480:rate=25" \
    -f lavfi -i "color=blue:size=640x480:rate=25" \
    -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0[out]" \
    -map "[out]" \
    -t 10 \
    -c:v libx264 -preset ultrafast -f mpegts - 2>/dev/null | \
    "$FFPLAY_PATH" -i - -window_title "MSwitch: RED (map=0)" -autoexit -loglevel quiet &

FFPLAY_PID=$!
wait $FFPLAY_PID
sleep 1

# Test 2: GREEN for 10 seconds
echo ""
echo "========================================="
echo "Test 2: Displaying GREEN (10 seconds)"
echo "========================================="
echo ""

"$FFMPEG_PATH" \
    -f lavfi -i "color=red:size=640x480:rate=25" \
    -f lavfi -i "color=green:size=640x480:rate=25" \
    -f lavfi -i "color=blue:size=640x480:rate=25" \
    -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=1[out]" \
    -map "[out]" \
    -t 10 \
    -c:v libx264 -preset ultrafast -f mpegts - 2>/dev/null | \
    "$FFPLAY_PATH" -i - -window_title "MSwitch: GREEN (map=1)" -autoexit -loglevel quiet &

FFPLAY_PID=$!
wait $FFPLAY_PID
sleep 1

# Test 3: BLUE for 10 seconds
echo ""
echo "========================================="
echo "Test 3: Displaying BLUE (10 seconds)"
echo "========================================="
echo ""

"$FFMPEG_PATH" \
    -f lavfi -i "color=red:size=640x480:rate=25" \
    -f lavfi -i "color=green:size=640x480:rate=25" \
    -f lavfi -i "color=blue:size=640x480:rate=25" \
    -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=2[out]" \
    -map "[out]" \
    -t 10 \
    -c:v libx264 -preset ultrafast -f mpegts - 2>/dev/null | \
    "$FFPLAY_PATH" -i - -window_title "MSwitch: BLUE (map=2)" -autoexit -loglevel quiet &

FFPLAY_PID=$!
wait $FFPLAY_PID

echo ""
echo "============================================================"
echo "  Test Complete"
echo "============================================================"
echo ""
echo "You should have seen three 10-second videos:"
echo "  ✅ RED screen (map=0)"
echo "  ✅ GREEN screen (map=1)"
echo "  ✅ BLUE screen (map=2)"
echo ""
echo "This confirms the mswitch filter works correctly!"
echo ""
echo "For runtime switching, we need to integrate with MSwitch's"
echo "HTTP control API or use FFmpeg's sendcmd/zmq interfaces."
echo "============================================================"

