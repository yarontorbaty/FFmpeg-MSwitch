#!/bin/bash
# MSwitch Distinct Demo - Very different visual patterns for each source
# This demo creates extremely distinct visual patterns to make failover obvious

set -e

# Configuration
FFMPEG_PATH="./ffmpeg"
FFMPEG_BREW_PATH="/opt/homebrew/bin/ffmpeg"
FFPLAY_PATH="/opt/homebrew/bin/ffplay"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    pkill -f "ffmpeg.*testsrc" 2>/dev/null || true
    pkill -f "ffplay" 2>/dev/null || true
    sleep 2
}

# Set up cleanup on exit
trap cleanup EXIT

# Generate very distinct sources
generate_distinct_sources() {
    echo "Starting sources..."
    
    # Source 1: Bright RED with high contrast
    echo "Starting Source 1 (RED) on port 12346..."
    "$FFMPEG_BREW_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                        -f lavfi -i "sine=frequency=1000" \
                        -vf "eq=contrast=2.0:brightness=0.5:saturation=3.0" \
                        -c:v libx264 -preset ultrafast -tune zerolatency \
                        -c:a aac -b:a 128k \
                        -f mpegts udp://127.0.0.1:12346?fifo_size=1000000 \
                        -loglevel info &
    SOURCE1_PID=$!
    echo "Source 1 PID: $SOURCE1_PID"
    
    # Source 2: Bright GREEN with different contrast
    echo "Starting Source 2 (GREEN) on port 12347..."
    "$FFMPEG_BREW_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                        -f lavfi -i "sine=frequency=2000" \
                        -vf "eq=contrast=1.5:brightness=0.3:saturation=2.5" \
                        -c:v libx264 -preset ultrafast -tune zerolatency \
                        -c:a aac -b:a 128k \
                        -f mpegts udp://127.0.0.1:12347?fifo_size=1000000 \
                        -loglevel info &
    SOURCE2_PID=$!
    echo "Source 2 PID: $SOURCE2_PID"
    
    # Source 3: Bright BLUE with different contrast
    echo "Starting Source 3 (BLUE) on port 12348..."
    "$FFMPEG_BREW_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                        -f lavfi -i "sine=frequency=3000" \
                        -vf "eq=contrast=1.0:brightness=0.1:saturation=1.0" \
                        -c:v libx264 -preset ultrafast -tune zerolatency \
                        -c:a aac -b:a 128k \
                        -f mpegts udp://127.0.0.1:12348?fifo_size=1000000 \
                        -loglevel info &
    SOURCE3_PID=$!
    echo "Source 3 PID: $SOURCE3_PID"
    
    sleep 3
    echo "Checking if sources are running..."
    ps aux | grep -E "(ffmpeg|testsrc)" | grep -v grep || echo "No ffmpeg processes found!"
    echo "Sources ready"
}

# Test with fullscreen windows
test_fullscreen_sources() {
    echo "Testing individual sources..."
    
    # Test Source 1 (RED) - Fullscreen
    echo "Showing RED source (8s)"
    echo "Starting ffplay for RED source..."
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12346" \
                   -window_title "Source 1 - BRIGHT RED" \
                   -fs \
                   -loglevel info &
    FFPLAY1_PID=$!
    echo "FFPLAY1 PID: $FFPLAY1_PID"
    sleep 2
    echo "Checking if ffplay is running..."
    ps aux | grep ffplay | grep -v grep || echo "No ffplay processes found!"
    sleep 6
    echo "Killing RED source player"
    kill $FFPLAY1_PID 2>/dev/null || true
    
    # Test Source 2 (GREEN) - Fullscreen
    echo "Showing GREEN source (8s)"
    echo "Starting ffplay for GREEN source..."
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12347" \
                   -window_title "Source 2 - BRIGHT GREEN" \
                   -fs \
                   -loglevel info &
    FFPLAY2_PID=$!
    echo "FFPLAY2 PID: $FFPLAY2_PID"
    sleep 2
    echo "Checking if ffplay is running..."
    ps aux | grep ffplay | grep -v grep || echo "No ffplay processes found!"
    sleep 6
    echo "Killing GREEN source player"
    kill $FFPLAY2_PID 2>/dev/null || true
    
    # Test Source 3 (BLUE) - Fullscreen
    echo "Showing BLUE source (8s)"
    echo "Starting ffplay for BLUE source..."
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12348" \
                   -window_title "Source 3 - BRIGHT BLUE" \
                   -fs \
                   -loglevel info &
    FFPLAY3_PID=$!
    echo "FFPLAY3 PID: $FFPLAY3_PID"
    sleep 2
    echo "Checking if ffplay is running..."
    ps aux | grep ffplay | grep -v grep || echo "No ffplay processes found!"
    sleep 6
    echo "Killing BLUE source player"
    kill $FFPLAY3_PID 2>/dev/null || true
}

# Test all sources simultaneously
test_all_sources_simultaneously() {
    echo "Showing all sources simultaneously (15s)"
    
    # Show all three sources at once
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12346" \
                   -window_title "Source 1 - RED" \
                   -fs \
                   -loglevel error 2>/dev/null &
    FFPLAY1_PID=$!
    
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12347" \
                   -window_title "Source 2 - GREEN" \
                   -fs \
                   -loglevel error 2>/dev/null &
    FFPLAY2_PID=$!
    
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12348" \
                   -window_title "Source 3 - BLUE" \
                   -fs \
                   -loglevel error 2>/dev/null &
    FFPLAY3_PID=$!
    
    sleep 15
    
    # Kill all players
    kill $FFPLAY1_PID 2>/dev/null || true
    kill $FFPLAY2_PID 2>/dev/null || true
    kill $FFPLAY3_PID 2>/dev/null || true
}

# Test failover with visual feedback
test_failover_visual() {
    echo "Testing failover simulation..."
    
    # Start with all sources
    echo "Starting all sources"
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12346" \
                   -window_title "Source 1 - RED" \
                   -fs \
                   -loglevel error 2>/dev/null &
    FFPLAY1_PID=$!
    
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12347" \
                   -window_title "Source 2 - GREEN" \
                   -fs \
                   -loglevel error 2>/dev/null &
    FFPLAY2_PID=$!
    
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12348" \
                   -window_title "Source 3 - BLUE" \
                   -fs \
                   -loglevel error 2>/dev/null &
    FFPLAY3_PID=$!
    
    sleep 5
    
    # Simulate Source 1 failure
    echo "Killing RED source (failover to GREEN/BLUE)"
    kill $SOURCE1_PID 2>/dev/null || true
    kill $FFPLAY1_PID 2>/dev/null || true
    
    sleep 5
    
    # Simulate Source 2 failure
    echo "Killing GREEN source (failover to BLUE only)"
    kill $SOURCE2_PID 2>/dev/null || true
    kill $FFPLAY2_PID 2>/dev/null || true
    
    sleep 5
    
    # Only Source 3 should be running
    echo "Only BLUE source remaining"
    sleep 5
    
    kill $FFPLAY3_PID 2>/dev/null || true
    echo "Failover test complete"
}

# Test basic ffplay functionality
test_basic_ffplay() {
    echo "Testing basic ffplay functionality..."
    echo "Starting simple test pattern for 5 seconds..."
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=5:size=640x480:rate=25" \
                   -window_title "Basic Test" \
                   -loglevel info &
    BASIC_PID=$!
    echo "Basic test PID: $BASIC_PID"
    sleep 2
    echo "Checking if basic ffplay is running..."
    ps aux | grep ffplay | grep -v grep || echo "No ffplay processes found!"
    sleep 3
    echo "Killing basic test"
    kill $BASIC_PID 2>/dev/null || true
    echo "Basic test complete"
}

# Main demo function
main() {
    # Check binaries
    if [ ! -f "$FFMPEG_PATH" ]; then
        echo -e "${RED}Error: Custom FFmpeg not found at $FFMPEG_PATH${NC}"
        exit 1
    fi
    
    if [ ! -f "$FFMPEG_BREW_PATH" ]; then
        echo -e "${RED}Error: Homebrew FFmpeg not found at $FFMPEG_BREW_PATH${NC}"
        exit 1
    fi
    
    if [ ! -f "$FFPLAY_PATH" ]; then
        echo -e "${RED}Error: ffplay not found at $FFPLAY_PATH${NC}"
        exit 1
    fi
    
    # Test basic ffplay first
    test_basic_ffplay
    
    # Generate distinct sources
    generate_distinct_sources
    
    # Test fullscreen sources
    test_fullscreen_sources
    
    # Test all sources simultaneously
    test_all_sources_simultaneously
    
    # Test failover with visual feedback
    test_failover_visual
}

# Run main function
main "$@"
