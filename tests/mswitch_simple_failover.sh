#!/bin/bash
# Simple MSwitch Failover Demo - Minimal version for testing
# This creates a simple failover demo that should be easier to see

set -e

# Configuration
FFMPEG_BREW_PATH="/opt/homebrew/bin/ffmpeg"
FFPLAY_PATH="/opt/homebrew/bin/ffplay"

echo "=== Simple MSwitch Failover Demo ==="
echo "This will show a single window that switches between 3 different sources"
echo "Press Ctrl+C to stop"
echo ""

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    pkill -f "ffmpeg.*testsrc" 2>/dev/null || true
    pkill -f "ffplay" 2>/dev/null || true
    sleep 1
}

trap cleanup EXIT

# Generate 3 different sources
echo "Starting 3 different sources..."

# Source 1: Normal test pattern
"$FFMPEG_BREW_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                    -f lavfi -i "sine=frequency=440" \
                    -c:v libx264 -preset ultrafast \
                    -c:a aac -b:a 128k \
                    -f mpegts udp://127.0.0.1:12346 \
                    -loglevel error &

# Source 2: Different pattern (inverted colors)
"$FFMPEG_BREW_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                    -f lavfi -i "sine=frequency=880" \
                    -vf "negate" \
                    -c:v libx264 -preset ultrafast \
                    -c:a aac -b:a 128k \
                    -f mpegts udp://127.0.0.1:12347 \
                    -loglevel error &

# Source 3: Solid color
"$FFMPEG_BREW_PATH" -f lavfi -i "color=red:size=640x480:rate=25" \
                    -f lavfi -i "sine=frequency=1320" \
                    -c:v libx264 -preset ultrafast \
                    -c:a aac -b:a 128k \
                    -f mpegts udp://127.0.0.1:12348 \
                    -loglevel error &

sleep 3
echo "Sources ready!"

# Start the output player first
echo "Starting output player..."
"$FFPLAY_PATH" -i udp://127.0.0.1:12349 \
               -window_title "MSwitch Output - Watch for Changes!" \
               -noborder -alwaysontop \
               -loglevel error &
PLAYER_PID=$!

sleep 2

echo ""
echo "=== Failover Sequence Starting ==="

# Phase 1: Show normal test pattern (Source 1)
echo "Phase 1: Normal test pattern (440Hz tone) - 8 seconds"
"$FFMPEG_BREW_PATH" -i udp://127.0.0.1:12346 \
                    -c copy \
                    -f mpegts udp://127.0.0.1:12349 \
                    -loglevel error &
CURRENT_PID=$!
sleep 8

# Phase 2: Switch to inverted pattern (Source 2)
echo "Phase 2: SWITCHING to inverted pattern (880Hz tone) - 8 seconds"
kill $CURRENT_PID 2>/dev/null || true
"$FFMPEG_BREW_PATH" -i udp://127.0.0.1:12347 \
                    -c copy \
                    -f mpegts udp://127.0.0.1:12349 \
                    -loglevel error &
CURRENT_PID=$!
sleep 8

# Phase 3: Switch to red screen (Source 3)
echo "Phase 3: SWITCHING to red screen (1320Hz tone) - 8 seconds"
kill $CURRENT_PID 2>/dev/null || true
"$FFMPEG_BREW_PATH" -i udp://127.0.0.1:12348 \
                    -c copy \
                    -f mpegts udp://127.0.0.1:12349 \
                    -loglevel error &
CURRENT_PID=$!
sleep 8

# Phase 4: Back to normal (Source 1)
echo "Phase 4: SWITCHING back to normal pattern (440Hz tone) - 8 seconds"
kill $CURRENT_PID 2>/dev/null || true
"$FFMPEG_BREW_PATH" -i udp://127.0.0.1:12346 \
                    -c copy \
                    -f mpegts udp://127.0.0.1:12349 \
                    -loglevel error &
CURRENT_PID=$!
sleep 8

echo ""
echo "=== Demo Complete ==="
echo "You should have seen the window change between:"
echo "1. Normal test pattern"
echo "2. Inverted (negative) pattern"  
echo "3. Solid red screen"
echo "4. Back to normal pattern"

# Cleanup
kill $CURRENT_PID 2>/dev/null || true
kill $PLAYER_PID 2>/dev/null || true

echo "Demo finished!"
