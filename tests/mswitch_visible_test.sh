#!/bin/bash
# MSwitch Visible Test - Make ffplay windows more visible
# This test creates large, bright test patterns that should be easily visible

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

# Test with large, bright test pattern
test_visible_ffplay() {
    echo -e "${BLUE}Testing ffplay with large, bright test pattern...${NC}"
    echo -e "${YELLOW}You should see a LARGE, BRIGHT test pattern window for 15 seconds${NC}"
    echo -e "${YELLOW}Look for a window with title 'MSwitch Visible Test'${NC}"
    
    # Create a large, bright test pattern
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=15:size=1280x720:rate=25" \
                   -window_title "MSwitch Visible Test" \
                   -x 100 -y 100 \
                   -vf "scale=1280:720" &
    FFPLAY_PID=$!
    
    # Wait for 15 seconds
    sleep 15
    
    # Kill ffplay
    kill $FFPLAY_PID 2>/dev/null || true
    
    echo -e "${GREEN}Visible test completed${NC}"
}

# Test with multiple large windows
test_multiple_visible() {
    echo -e "${BLUE}Testing multiple large, visible windows...${NC}"
    echo -e "${YELLOW}You should see 3 LARGE, BRIGHT test pattern windows for 15 seconds${NC}"
    
    # Create multiple large, bright test patterns
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=15:size=640x480:rate=25" \
                   -window_title "MSwitch Test 1" \
                   -x 50 -y 50 &
    FFPLAY1_PID=$!
    
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=15:size=640x480:rate=25" \
                   -window_title "MSwitch Test 2" \
                   -x 700 -y 50 &
    FFPLAY2_PID=$!
    
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=15:size=640x480:rate=25" \
                   -window_title "MSwitch Test 3" \
                   -x 50 -y 550 &
    FFPLAY3_PID=$!
    
    # Wait for 15 seconds
    sleep 15
    
    # Kill all processes
    kill $FFPLAY1_PID 2>/dev/null || true
    kill $FFPLAY2_PID 2>/dev/null || true
    kill $FFPLAY3_PID 2>/dev/null || true
    
    echo -e "${GREEN}Multiple visible test completed${NC}"
}

# Test with audio to make it more obvious
test_audio_visible() {
    echo -e "${BLUE}Testing ffplay with audio (you should hear a tone)...${NC}"
    echo -e "${YELLOW}You should see a test pattern AND hear a 1000Hz tone for 10 seconds${NC}"
    
    # Create test pattern with audio
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=10:size=800x600:rate=25" \
                   -f lavfi -i "sine=frequency=1000" \
                   -window_title "MSwitch Audio Test" \
                   -x 200 -y 200 &
    FFPLAY_PID=$!
    
    # Wait for 10 seconds
    sleep 10
    
    # Kill ffplay
    kill $FFPLAY_PID 2>/dev/null || true
    
    echo -e "${GREEN}Audio test completed${NC}"
}

# Main test runner
main() {
    echo -e "${BLUE}MSwitch Visible Test${NC}"
    echo -e "${BLUE}===================${NC}"
    
    # Check if ffplay exists
    if [ ! -f "$FFPLAY_PATH" ]; then
        echo -e "${RED}Error: ffplay not found at $FFPLAY_PATH${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}Testing ffplay with large, visible windows...${NC}"
    
    # Test 1: Single large window
    test_visible_ffplay
    
    # Test 2: Multiple large windows
    test_multiple_visible
    
    # Test 3: Audio test
    test_audio_visible
    
    echo -e "\n${GREEN}All visible tests completed!${NC}"
    echo -e "${CYAN}If you saw the large, bright test pattern windows, ffplay is working correctly.${NC}"
    echo -e "${CYAN}If you didn't see any windows, check:${NC}"
    echo -e "${CYAN}  - Are there any windows behind other applications?${NC}"
    echo -e "${CYAN}  - Try moving other windows to see if ffplay windows are hidden${NC}"
    echo -e "${CYAN}  - Check if your display scaling is set correctly${NC}"
}

# Run main function
main "$@"
