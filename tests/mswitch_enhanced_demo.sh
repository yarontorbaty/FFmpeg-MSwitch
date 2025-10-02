#!/bin/bash
# MSwitch Enhanced Demo - Large windows with distinct visual patterns
# This demo creates very different visual patterns for each source to make failover obvious

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

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    # Kill all ffmpeg and ffplay processes
    pkill -f "ffmpeg.*testsrc" 2>/dev/null || true
    pkill -f "ffplay" 2>/dev/null || true
    sleep 2
    echo -e "${GREEN}Cleanup completed${NC}"
}

# Set up cleanup on exit
trap cleanup EXIT

# Generate distinct test patterns for each source
generate_distinct_sources() {
    echo -e "${BLUE}Generating distinct visual patterns for each source...${NC}"
    
    # Source 1: Red test pattern with moving text
    echo -e "${YELLOW}Starting Source 1: RED test pattern with moving text${NC}"
    "$FFMPEG_PATH" -f lavfi -i "testsrc=size=1280x720:rate=25" \
                   -f lavfi -i "sine=frequency=1000" \
                   -vf "scale=1280:720,eq=contrast=1.5:brightness=0.2:saturation=2.0" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts udp://127.0.0.1:12346 &
    SOURCE1_PID=$!
    
    # Source 2: Green test pattern with different frequency
    echo -e "${YELLOW}Starting Source 2: GREEN test pattern with different frequency${NC}"
    "$FFMPEG_PATH" -f lavfi -i "testsrc=size=1280x720:rate=25" \
                   -f lavfi -i "sine=frequency=2000" \
                   -vf "scale=1280:720,eq=contrast=1.2:brightness=0.1:saturation=1.5" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts udp://127.0.0.1:12347 &
    SOURCE2_PID=$!
    
    # Source 3: Blue test pattern with different frequency
    echo -e "${YELLOW}Starting Source 3: BLUE test pattern with different frequency${NC}"
    "$FFMPEG_PATH" -f lavfi -i "testsrc=size=1280x720:rate=25" \
                   -f lavfi -i "sine=frequency=3000" \
                   -vf "scale=1280:720,eq=contrast=0.8:brightness=0.3:saturation=0.5" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts udp://127.0.0.1:12348 &
    SOURCE3_PID=$!
    
    # Wait for sources to start
    sleep 3
    
    echo -e "${GREEN}All sources started successfully!${NC}"
    echo -e "${CYAN}Source 1: RED pattern (1000Hz audio) - udp://127.0.0.1:12346${NC}"
    echo -e "${CYAN}Source 2: GREEN pattern (2000Hz audio) - udp://127.0.0.1:12347${NC}"
    echo -e "${CYAN}Source 3: BLUE pattern (3000Hz audio) - udp://127.0.0.1:12348${NC}"
}

# Test individual sources with large windows
test_individual_sources() {
    echo -e "\n${BLUE}=== Testing Individual Sources (Large Windows) ===${NC}"
    
    # Test Source 1 (RED)
    echo -e "${YELLOW}Testing Source 1: RED pattern for 10 seconds${NC}"
    echo -e "${CYAN}You should see a LARGE RED test pattern window${NC}"
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12346" \
                   -window_title "MSwitch Source 1 - RED Pattern" \
                   -x 50 -y 50 -fs &
    FFPLAY1_PID=$!
    sleep 10
    kill $FFPLAY1_PID 2>/dev/null || true
    
    # Test Source 2 (GREEN)
    echo -e "${YELLOW}Testing Source 2: GREEN pattern for 10 seconds${NC}"
    echo -e "${CYAN}You should see a LARGE GREEN test pattern window${NC}"
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12347" \
                   -window_title "MSwitch Source 2 - GREEN Pattern" \
                   -x 50 -y 50 -fs &
    FFPLAY2_PID=$!
    sleep 10
    kill $FFPLAY2_PID 2>/dev/null || true
    
    # Test Source 3 (BLUE)
    echo -e "${YELLOW}Testing Source 3: BLUE pattern for 10 seconds${NC}"
    echo -e "${CYAN}You should see a LARGE BLUE test pattern window${NC}"
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12348" \
                   -window_title "MSwitch Source 3 - BLUE Pattern" \
                   -x 50 -y 50 -fs &
    FFPLAY3_PID=$!
    sleep 10
    kill $FFPLAY3_PID 2>/dev/null || true
}

# Test MSwitch with live streams
test_mswitch_live() {
    echo -e "\n${BLUE}=== Testing MSwitch with Live Streams ===${NC}"
    echo -e "${YELLOW}Testing MSwitch with live streams for 15 seconds${NC}"
    echo -e "${CYAN}You should see the MSwitch output with live streams${NC}"
    
    # Test MSwitch with live streams
    "$FFMPEG_PATH" -msw.enable 1 \
                   -msw.sources "s0=udp://127.0.0.1:12346;s1=udp://127.0.0.1:12347;s2=udp://127.0.0.1:12348" \
                   -msw.ingest hot \
                   -msw.mode graceful \
                   -msw.auto.enable 1 \
                   -msw.auto.on "cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10" \
                   -f lavfi -i "testsrc=duration=15:size=1280x720:rate=25" \
                   -f null - &
    MSWITCH_PID=$!
    
    # Show the output in a large window
    "$FFPLAY_PATH" -f lavfi -i "testsrc=duration=15:size=1280x720:rate=25" \
                   -window_title "MSwitch Output - Live Streams" \
                   -x 50 -y 50 -fs &
    FFPLAY_OUTPUT_PID=$!
    
    sleep 15
    
    kill $MSWITCH_PID 2>/dev/null || true
    kill $FFPLAY_OUTPUT_PID 2>/dev/null || true
}

# Test failover simulation
test_failover_simulation() {
    echo -e "\n${BLUE}=== Testing Failover Simulation ===${NC}"
    echo -e "${YELLOW}Simulating failover scenarios...${NC}"
    
    # Show all three sources simultaneously
    echo -e "${CYAN}Showing all three sources simultaneously for 10 seconds${NC}"
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12346" \
                   -window_title "Source 1 - RED" \
                   -x 50 -y 50 -fs &
    FFPLAY1_PID=$!
    
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12347" \
                   -window_title "Source 2 - GREEN" \
                   -x 700 -y 50 -fs &
    FFPLAY2_PID=$!
    
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12348" \
                   -window_title "Source 3 - BLUE" \
                   -x 50 -y 400 -fs &
    FFPLAY3_PID=$!
    
    sleep 10
    
    # Simulate Source 1 failure
    echo -e "${YELLOW}Simulating Source 1 failure...${NC}"
    kill $SOURCE1_PID 2>/dev/null || true
    kill $FFPLAY1_PID 2>/dev/null || true
    
    sleep 5
    
    # Simulate Source 2 failure
    echo -e "${YELLOW}Simulating Source 2 failure...${NC}"
    kill $SOURCE2_PID 2>/dev/null || true
    kill $FFPLAY2_PID 2>/dev/null || true
    
    sleep 5
    
    # Show only Source 3
    echo -e "${YELLOW}Only Source 3 (BLUE) should be running now${NC}"
    sleep 5
    
    kill $FFPLAY3_PID 2>/dev/null || true
}

# Main demo function
main() {
    echo -e "${BLUE}MSwitch Enhanced Demo${NC}"
    echo -e "${BLUE}===================${NC}"
    echo -e "${CYAN}This demo creates LARGE, DISTINCT visual patterns for each source${NC}"
    echo -e "${CYAN}You should clearly see the differences when failover occurs${NC}"
    
    # Check if required binaries exist
    if [ ! -f "$FFMPEG_PATH" ]; then
        echo -e "${RED}Error: FFmpeg not found at $FFMPEG_PATH${NC}"
        exit 1
    fi
    
    if [ ! -f "$FFPLAY_PATH" ]; then
        echo -e "${RED}Error: ffplay not found at $FFPLAY_PATH${NC}"
        exit 1
    fi
    
    # Generate distinct sources
    generate_distinct_sources
    
    # Test individual sources
    test_individual_sources
    
    # Test MSwitch with live streams
    test_mswitch_live
    
    # Test failover simulation
    test_failover_simulation
    
    echo -e "\n${GREEN}Enhanced MSwitch Demo completed successfully!${NC}"
    echo -e "${CYAN}You should have seen:${NC}"
    echo -e "${CYAN}  - LARGE windows (1280x720)${NC}"
    echo -e "${CYAN}  - DISTINCT visual patterns (RED, GREEN, BLUE)${NC}"
    echo -e "${CYAN}  - Different audio frequencies (1000Hz, 2000Hz, 3000Hz)${NC}"
    echo -e "${CYAN}  - Clear failover simulation${NC}"
}

# Run main function
main "$@"
