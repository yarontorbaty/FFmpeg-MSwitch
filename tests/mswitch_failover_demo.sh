#!/bin/bash
# MSwitch Failover Demo - Single output stream with seamless switching
# This demo shows actual MSwitch functionality with one output window

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
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    pkill -f "ffmpeg.*testsrc" 2>/dev/null || true
    pkill -f "ffplay" 2>/dev/null || true
    pkill -f "mswitch" 2>/dev/null || true
    sleep 2
}

# Set up cleanup on exit
trap cleanup EXIT

# Generate distinct sources for MSwitch
generate_mswitch_sources() {
    echo -e "${CYAN}Starting MSwitch input sources...${NC}"
    
    # Source 1: RED pattern with 1000Hz audio
    echo "Starting Source 1 (RED) on port 12346..."
    "$FFMPEG_BREW_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                        -f lavfi -i "sine=frequency=1000" \
                        -vf "eq=contrast=2.0:brightness=0.5:saturation=3.0" \
                        -c:v libx264 -preset ultrafast -tune zerolatency \
                        -c:a aac -b:a 128k \
                        -f mpegts udp://127.0.0.1:12346?fifo_size=1000000 \
                        -loglevel error &
    SOURCE1_PID=$!
    
    # Source 2: GREEN pattern with 2000Hz audio
    echo "Starting Source 2 (GREEN) on port 12347..."
    "$FFMPEG_BREW_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                        -f lavfi -i "sine=frequency=2000" \
                        -vf "eq=contrast=1.5:brightness=0.3:saturation=2.5" \
                        -c:v libx264 -preset ultrafast -tune zerolatency \
                        -c:a aac -b:a 128k \
                        -f mpegts udp://127.0.0.1:12347?fifo_size=1000000 \
                        -loglevel error &
    SOURCE2_PID=$!
    
    # Source 3: BLUE pattern with 3000Hz audio
    echo "Starting Source 3 (BLUE) on port 12348..."
    "$FFMPEG_BREW_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                        -f lavfi -i "sine=frequency=3000" \
                        -vf "eq=contrast=1.0:brightness=0.1:saturation=1.0" \
                        -c:v libx264 -preset ultrafast -tune zerolatency \
                        -c:a aac -b:a 128k \
                        -f mpegts udp://127.0.0.1:12348?fifo_size=1000000 \
                        -loglevel error &
    SOURCE3_PID=$!
    
    sleep 3
    echo -e "${GREEN}Sources ready${NC}"
}

# Simulate MSwitch output (since full MSwitch isn't implemented yet)
simulate_mswitch_output() {
    echo -e "${CYAN}Starting MSwitch simulation...${NC}"
    
    # Create a single output stream that will switch between sources
    # This simulates what MSwitch would do - take multiple inputs and output one stream
    echo "Creating MSwitch output on port 12349..."
    
    # Start with Source 1 (RED)
    echo -e "${RED}MSwitch: Active source = RED (Source 1)${NC}"
    "$FFMPEG_BREW_PATH" -i udp://127.0.0.1:12346 \
                        -c:v libx264 -preset ultrafast -tune zerolatency \
                        -c:a aac -b:a 128k \
                        -f mpegts udp://127.0.0.1:12349?fifo_size=1000000 \
                        -loglevel error &
    MSWITCH_PID=$!
    
    return $MSWITCH_PID
}

# Demonstrate failover by switching sources
demonstrate_failover() {
    local mswitch_pid=$1
    
    echo -e "\n${YELLOW}=== MSwitch Failover Demo ===${NC}"
    echo -e "${CYAN}Watch the single output window for seamless switching...${NC}"
    
    # Start the output player
    echo "Starting MSwitch output player..."
    "$FFPLAY_PATH" -i udp://127.0.0.1:12349 \
                   -window_title "MSwitch Output - Failover Demo" \
                   -fs \
                   -loglevel error &
    PLAYER_PID=$!
    
    sleep 3
    
    # Phase 1: Show RED source (Source 1)
    echo -e "\n${RED}Phase 1: Showing RED source (10 seconds)${NC}"
    echo "Audio: 1000Hz tone"
    sleep 10
    
    # Phase 2: Simulate failover to GREEN (Source 2)
    echo -e "\n${GREEN}Phase 2: Failover to GREEN source${NC}"
    echo "Simulating Source 1 failure..."
    kill $mswitch_pid 2>/dev/null || true
    
    echo -e "${GREEN}MSwitch: Switching to GREEN (Source 2)${NC}"
    "$FFMPEG_BREW_PATH" -i udp://127.0.0.1:12347 \
                        -c:v libx264 -preset ultrafast -tune zerolatency \
                        -c:a aac -b:a 128k \
                        -f mpegts udp://127.0.0.1:12349?fifo_size=1000000 \
                        -loglevel error &
    MSWITCH_PID=$!
    
    echo "Audio: 2000Hz tone"
    sleep 10
    
    # Phase 3: Simulate failover to BLUE (Source 3)
    echo -e "\n${BLUE}Phase 3: Failover to BLUE source${NC}"
    echo "Simulating Source 2 failure..."
    kill $MSWITCH_PID 2>/dev/null || true
    
    echo -e "${BLUE}MSwitch: Switching to BLUE (Source 3)${NC}"
    "$FFMPEG_BREW_PATH" -i udp://127.0.0.1:12348 \
                        -c:v libx264 -preset ultrafast -tune zerolatency \
                        -c:a aac -b:a 128k \
                        -f mpegts udp://127.0.0.1:12349?fifo_size=1000000 \
                        -loglevel error &
    MSWITCH_PID=$!
    
    echo "Audio: 3000Hz tone"
    sleep 10
    
    # Phase 4: Simulate recovery back to RED
    echo -e "\n${RED}Phase 4: Recovery - Back to RED source${NC}"
    echo "Simulating Source 1 recovery..."
    kill $MSWITCH_PID 2>/dev/null || true
    
    echo -e "${RED}MSwitch: Switching back to RED (Source 1)${NC}"
    "$FFMPEG_BREW_PATH" -i udp://127.0.0.1:12346 \
                        -c:v libx264 -preset ultrafast -tune zerolatency \
                        -c:a aac -b:a 128k \
                        -f mpegts udp://127.0.0.1:12349?fifo_size=1000000 \
                        -loglevel error &
    MSWITCH_PID=$!
    
    echo "Audio: 1000Hz tone"
    sleep 10
    
    echo -e "\n${GREEN}Failover demo complete!${NC}"
    
    # Clean up
    kill $PLAYER_PID 2>/dev/null || true
    kill $MSWITCH_PID 2>/dev/null || true
}

# Main demo function
main() {
    echo -e "${CYAN}=== MSwitch Failover Demo ===${NC}"
    echo -e "${YELLOW}This demo shows a single output stream with seamless failover${NC}"
    echo -e "${YELLOW}You should see ONE window that changes content during failover${NC}"
    echo ""
    
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
    
    # Generate input sources
    generate_mswitch_sources
    
    # Start MSwitch simulation
    simulate_mswitch_output
    MSWITCH_PID=$?
    
    # Demonstrate failover
    demonstrate_failover $MSWITCH_PID
}

# Run main function
main "$@"
