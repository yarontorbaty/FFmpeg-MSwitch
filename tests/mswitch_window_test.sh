#!/bin/bash
# MSwitch Window Test - Force windows to appear on screen
# This test creates simple test patterns that should definitely be visible

set -e

# Configuration
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
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    pkill -f "ffplay" 2>/dev/null || true
    sleep 2
    echo -e "${GREEN}Cleanup completed${NC}"
}

# Set up cleanup on exit
trap cleanup EXIT

# Test simple test pattern
test_simple_pattern() {
    echo -e "${BLUE}Testing simple test pattern...${NC}"
    echo -e "${YELLOW}You should see a test pattern window for 10 seconds${NC}"
    
    # Create a simple test pattern with explicit window positioning
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=10:size=800x600:rate=25" \
                   -window_title "MSwitch Test Pattern" \
                   -x 100 -y 100 \
                   -noborder \
                   -alwaysontop &
    FFPLAY_PID=$!
    
    # Wait for 10 seconds
    sleep 10
    
    # Kill ffplay
    kill $FFPLAY_PID 2>/dev/null || true
    sleep 2
}

# Test with different window options
test_window_options() {
    echo -e "\n${BLUE}Testing different window options...${NC}"
    echo -e "${YELLOW}Testing window with different options for 8 seconds${NC}"
    
    # Try different window options
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=8:size=640x480:rate=25" \
                   -window_title "MSwitch Window Test" \
                   -x 200 -y 200 \
                   -noborder \
                   -alwaysontop \
                   -vf "scale=640:480" &
    FFPLAY_PID=$!
    
    sleep 8
    kill $FFPLAY_PID 2>/dev/null || true
    sleep 2
}

# Test with audio
test_with_audio() {
    echo -e "\n${BLUE}Testing with audio...${NC}"
    echo -e "${YELLOW}You should see a test pattern with audio for 8 seconds${NC}"
    
    # Create test pattern with audio
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=8:size=640x480:rate=25" \
                   -f lavfi -i "sine=frequency=1000" \
                   -window_title "MSwitch Audio Test" \
                   -x 300 -y 300 \
                   -noborder \
                   -alwaysontop &
    FFPLAY_PID=$!
    
    sleep 8
    kill $FFPLAY_PID 2>/dev/null || true
    sleep 2
}

# Test multiple windows
test_multiple_windows() {
    echo -e "\n${BLUE}Testing multiple windows...${NC}"
    echo -e "${YELLOW}You should see 3 test pattern windows for 10 seconds${NC}"
    
    # Create multiple windows
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=10:size=400x300:rate=25" \
                   -window_title "Window 1" \
                   -x 50 -y 50 \
                   -noborder \
                   -alwaysontop &
    FFPLAY1_PID=$!
    
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=10:size=400x300:rate=25" \
                   -window_title "Window 2" \
                   -x 500 -y 50 \
                   -noborder \
                   -alwaysontop &
    FFPLAY2_PID=$!
    
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=10:size=400x300:rate=25" \
                   -window_title "Window 3" \
                   -x 50 -y 400 \
                   -noborder \
                   -alwaysontop &
    FFPLAY3_PID=$!
    
    sleep 10
    
    # Kill all windows
    kill $FFPLAY1_PID 2>/dev/null || true
    kill $FFPLAY2_PID 2>/dev/null || true
    kill $FFPLAY3_PID 2>/dev/null || true
    sleep 2
}

# Test with explicit display
test_explicit_display() {
    echo -e "\n${BLUE}Testing with explicit display...${NC}"
    echo -e "${YELLOW}Testing with explicit display settings for 8 seconds${NC}"
    
    # Try with explicit display settings
    DISPLAY=:0 "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=8:size=640x480:rate=25" \
                   -window_title "MSwitch Display Test" \
                   -x 400 -y 400 \
                   -noborder \
                   -alwaysontop &
    FFPLAY_PID=$!
    
    sleep 8
    kill $FFPLAY_PID 2>/dev/null || true
    sleep 2
}

# Main test function
main() {
    echo -e "${BLUE}MSwitch Window Test${NC}"
    echo -e "${BLUE}==================${NC}"
    echo -e "${CYAN}This test tries different approaches to make ffplay windows visible${NC}"
    echo -e "${CYAN}If you see windows, the test is working${NC}"
    
    # Check if ffplay exists
    if [ ! -f "$FFPLAY_PATH" ]; then
        echo -e "${RED}Error: ffplay not found at $FFPLAY_PATH${NC}"
        exit 1
    fi
    
    # Test simple pattern
    test_simple_pattern
    
    # Test window options
    test_window_options
    
    # Test with audio
    test_with_audio
    
    # Test multiple windows
    test_multiple_windows
    
    # Test explicit display
    test_explicit_display
    
    echo -e "\n${GREEN}Window Test completed!${NC}"
    echo -e "${CYAN}If you saw any windows, ffplay is working correctly${NC}"
    echo -e "${CYAN}If you didn't see windows, there might be a display issue${NC}"
}

# Run main function
main "$@"
