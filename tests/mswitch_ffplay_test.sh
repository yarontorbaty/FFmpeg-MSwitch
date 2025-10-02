#!/bin/bash
# MSwitch FFplay Test - Simple test to verify ffplay windows are visible
# This test creates a simple test pattern and shows it in ffplay

set -e

# Configuration
FFMPEG_PATH="./ffmpeg"
FFPLAY_PATH="/opt/homebrew/bin/ffplay"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test ffplay with simple test pattern
test_ffplay_simple() {
    echo -e "${BLUE}Testing ffplay with simple test pattern...${NC}"
    echo -e "${YELLOW}You should see a test pattern window for 10 seconds${NC}"
    
    # Create a simple test pattern and show it
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=10:size=640x480:rate=25" -window_title "MSwitch Test Pattern" &
    FFPLAY_PID=$!
    
    # Wait for 10 seconds
    sleep 10
    
    # Kill ffplay
    kill $FFPLAY_PID 2>/dev/null || true
    
    echo -e "${GREEN}FFplay test completed${NC}"
}

# Test ffplay with live stream
test_ffplay_live_stream() {
    echo -e "${BLUE}Testing ffplay with live stream...${NC}"
    
    # Start a live stream in background
    echo -e "${YELLOW}Starting live stream...${NC}"
    "$FFMPEG_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                   -f lavfi -i "sine=frequency=1000" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts udp://127.0.0.1:12345 &
    STREAM_PID=$!
    
    # Wait for stream to start
    sleep 3
    
    echo -e "${YELLOW}You should see a live stream window for 10 seconds${NC}"
    
    # Show the live stream
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12345" -window_title "MSwitch Live Stream" &
    FFPLAY_PID=$!
    
    # Wait for 10 seconds
    sleep 10
    
    # Kill both processes
    kill $FFPLAY_PID 2>/dev/null || true
    kill $STREAM_PID 2>/dev/null || true
    
    echo -e "${GREEN}Live stream test completed${NC}"
}

# Test ffplay with multiple windows
test_ffplay_multiple() {
    echo -e "${BLUE}Testing ffplay with multiple windows...${NC}"
    
    # Start multiple test patterns
    echo -e "${YELLOW}You should see 3 test pattern windows for 10 seconds${NC}"
    
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=10:size=320x240:rate=25" -window_title "Test 1" &
    FFPLAY1_PID=$!
    
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=10:size=320x240:rate=25" -window_title "Test 2" &
    FFPLAY2_PID=$!
    
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=10:size=320x240:rate=25" -window_title "Test 3" &
    FFPLAY3_PID=$!
    
    # Wait for 10 seconds
    sleep 10
    
    # Kill all processes
    kill $FFPLAY1_PID 2>/dev/null || true
    kill $FFPLAY2_PID 2>/dev/null || true
    kill $FFPLAY3_PID 2>/dev/null || true
    
    echo -e "${GREEN}Multiple windows test completed${NC}"
}

# Main test runner
main() {
    echo -e "${BLUE}MSwitch FFplay Test${NC}"
    echo -e "${BLUE}===================${NC}"
    
    # Check if required binaries exist
    if [ ! -f "$FFMPEG_PATH" ]; then
        echo -e "${RED}Error: FFmpeg not found at $FFMPEG_PATH${NC}"
        exit 1
    fi
    
    if [ ! -f "$FFPLAY_PATH" ]; then
        echo -e "${RED}Error: ffplay not found at $FFPLAY_PATH${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}Testing ffplay functionality...${NC}"
    
    # Test 1: Simple test pattern
    test_ffplay_simple
    
    # Test 2: Live stream
    test_ffplay_live_stream
    
    # Test 3: Multiple windows
    test_ffplay_multiple
    
    echo -e "\n${GREEN}All ffplay tests completed successfully!${NC}"
    echo -e "${CYAN}If you saw the test pattern windows, ffplay is working correctly.${NC}"
    echo -e "${CYAN}If you didn't see any windows, there might be a display issue.${NC}"
}

# Run main function
main "$@"
