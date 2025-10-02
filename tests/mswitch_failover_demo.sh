#!/bin/bash
# MSwitch Failover Demo - Demonstrates real multi-source failover functionality
# This demo uses the actual MSwitch feature with multiple concurrent sources

set -e

# Configuration
FFMPEG_PATH="./ffmpeg"
FFMPEG_BREW_PATH="/opt/homebrew/bin/ffmpeg"
FFPLAY_PATH="/opt/homebrew/bin/ffplay"
MSWITCH_WEBHOOK_PORT=8099

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
    # Kill any webhook processes
    pkill -f "curl.*$MSWITCH_WEBHOOK_PORT" 2>/dev/null || true
    sleep 2
}

# Set up cleanup on exit
trap cleanup EXIT

# Kill all existing FFmpeg processes
cleanup_existing_processes() {
    echo -e "${YELLOW}Killing all existing FFmpeg processes...${NC}"
    pkill -f ffmpeg || true
    sleep 2
    echo -e "${GREEN}Cleanup completed${NC}"
}

# Generate distinct sources for MSwitch
generate_mswitch_sources() {
    echo -e "${CYAN}Starting MSwitch input sources...${NC}"
    
    # Source 1: RED pattern with 1000Hz audio on multicast 225.10.10.1:12346
    echo "Starting Source 1 (RED) on multicast 225.10.10.1:12346..."
    "$FFMPEG_BREW_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" -re \
                        -f lavfi -i "sine=frequency=1000" \
                        -vf "eq=contrast=2.0:brightness=0.5:saturation=3.0" \
                        -c:v libx264 -preset ultrafast -tune zerolatency -g 50 -pix_fmt yuv420p \
                        -c:a aac -b:a 128k \
                        -f mpegts "udp://225.10.10.1:12346?fifo_size=1000000" \
                        -loglevel info &
    SOURCE1_PID=$!
    
    # Source 2: GREEN pattern with 2000Hz audio on multicast 225.10.10.2:12347
    echo "Starting Source 2 (GREEN) on multicast 225.10.10.2:12347..."
    "$FFMPEG_BREW_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" -re \
                        -f lavfi -i "sine=frequency=2000" \
                        -vf "eq=contrast=1.5:brightness=0.3:saturation=2.5" \
                        -c:v libx264 -preset ultrafast -tune zerolatency -g 50 -pix_fmt yuv420p \
                        -c:a aac -b:a 128k \
                        -f mpegts "udp://225.10.10.2:12347?fifo_size=1000000" \
                        -loglevel info &
    SOURCE2_PID=$!
    
    # Source 3: BLUE pattern with 3000Hz audio on multicast 225.10.10.3:12348
    echo "Starting Source 3 (BLUE) on multicast 225.10.10.3:12348..."
    "$FFMPEG_BREW_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" -re \
                        -f lavfi -i "sine=frequency=3000" \
                        -vf "eq=contrast=1.0:brightness=0.1:saturation=1.0" \
                        -c:v libx264 -preset ultrafast -tune zerolatency -g 50 -pix_fmt yuv420p \
                        -c:a aac -b:a 128k \
                        -f mpegts "udp://225.10.10.3:12348?fifo_size=1000000" \
                        -loglevel info &
    SOURCE3_PID=$!
    
    sleep 5
    echo -e "${GREEN}All sources ready for MSwitch${NC}"
}

# Start MSwitch with real multi-source functionality
start_mswitch() {
    local mode=${1:-graceful}
    local ingest_mode=${2:-hot}
    
    echo -e "${CYAN}Starting MSwitch with mode: $mode, ingestion: $ingest_mode${NC}"
    
    # Use the custom FFmpeg build with MSwitch support
    "$FFMPEG_PATH" \
        -msw.enable \
        -msw.sources "s0=udp://225.10.10.1:12346;s1=udp://225.10.10.2:12347;s2=udp://225.10.10.3:12348" \
        -msw.ingest "$ingest_mode" \
        -msw.mode "$mode" \
        -msw.buffer_ms 1000 \
        -msw.webhook.enable \
        -msw.webhook.port "$MSWITCH_WEBHOOK_PORT" \
        -msw.cli.enable \
        -msw.auto.enable \
        -c:v libx264 -preset ultrafast -tune zerolatency -g 50 -pix_fmt yuv420p \
        -c:a aac -b:a 128k \
        -f mpegts "udp://127.0.0.1:12349?fifo_size=1000000" \
        -loglevel info &
    
    MSWITCH_PID=$!
    
    # Wait for MSwitch to initialize
    sleep 3
    
    # Test webhook connectivity
    if curl -s "http://127.0.0.1:$MSWITCH_WEBHOOK_PORT/status" > /dev/null 2>&1; then
        echo -e "${GREEN}MSwitch webhook interface ready on port $MSWITCH_WEBHOOK_PORT${NC}"
    else
        echo -e "${YELLOW}Warning: MSwitch webhook interface not responding${NC}"
    fi
    
    return $MSWITCH_PID
}

# Demonstrate failover using webhook commands
demonstrate_failover() {
    local mswitch_pid=$1
    
    echo -e "\n${YELLOW}=== MSwitch Failover Demo ===${NC}"
    echo -e "${CYAN}Watch the single output window for seamless switching...${NC}"
    
    # Start the output player
    echo "Starting MSwitch output player..."
    "$FFPLAY_PATH" -i "udp://127.0.0.1:12349" \
                   -window_title "MSwitch Output - Failover Demo" \
                   -fs \
                   -loglevel info &
    PLAYER_PID=$!
    
    sleep 3
    
    # Phase 1: Show initial source (s0 - RED)
    echo -e "\n${RED}Phase 1: Starting with RED source (s0) - 10 seconds${NC}"
    echo "Audio: 1000Hz tone"
    curl -s -X POST "http://127.0.0.1:$MSWITCH_WEBHOOK_PORT/switch" \
         -H "Content-Type: application/json" \
         -d '{"source": "s0"}' || echo "Webhook switch failed, but may already be on s0"
    sleep 10
    
    # Phase 2: Switch to GREEN (s1)
    echo -e "\n${GREEN}Phase 2: Switching to GREEN source (s1)${NC}"
    echo "Using webhook to switch sources..."
    if curl -s -X POST "http://127.0.0.1:$MSWITCH_WEBHOOK_PORT/switch" \
            -H "Content-Type: application/json" \
            -d '{"source": "s1"}'; then
        echo -e "${GREEN}✓ Successfully switched to GREEN source${NC}"
    else
        echo -e "${RED}✗ Webhook switch failed${NC}"
    fi
    echo "Audio: 2000Hz tone"
    sleep 10
    
    # Phase 3: Switch to BLUE (s2)
    echo -e "\n${BLUE}Phase 3: Switching to BLUE source (s2)${NC}"
    echo "Using webhook to switch sources..."
    if curl -s -X POST "http://127.0.0.1:$MSWITCH_WEBHOOK_PORT/switch" \
            -H "Content-Type: application/json" \
            -d '{"source": "s2"}'; then
        echo -e "${BLUE}✓ Successfully switched to BLUE source${NC}"
    else
        echo -e "${RED}✗ Webhook switch failed${NC}"
    fi
    echo "Audio: 3000Hz tone"
    sleep 10
    
    # Phase 4: Switch back to RED (s0)
    echo -e "\n${RED}Phase 4: Switching back to RED source (s0)${NC}"
    echo "Demonstrating failback to primary source..."
    if curl -s -X POST "http://127.0.0.1:$MSWITCH_WEBHOOK_PORT/switch" \
            -H "Content-Type: application/json" \
            -d '{"source": "s0"}'; then
        echo -e "${RED}✓ Successfully switched back to RED source${NC}"
    else
        echo -e "${RED}✗ Webhook switch failed${NC}"
    fi
    echo "Audio: 1000Hz tone"
    sleep 10
    
    # Show final status
    echo -e "\n${CYAN}Getting final MSwitch status...${NC}"
    curl -s "http://127.0.0.1:$MSWITCH_WEBHOOK_PORT/status" | head -10 || echo "Status unavailable"
    
    echo -e "\n${GREEN}Multi-source failover demo complete!${NC}"
    echo -e "${YELLOW}Note: This used REAL MSwitch functionality with concurrent sources${NC}"
    
    # Clean up
    kill $PLAYER_PID 2>/dev/null || true
}

# Main demo function
main() {
    local mode=${1:-graceful}
    local ingest_mode=${2:-hot}
    
    # Clean up any existing FFmpeg processes first
    cleanup_existing_processes
    
    echo -e "${CYAN}=== MSwitch Multi-Source Failover Demo ===${NC}"
    echo -e "${YELLOW}This demo shows REAL multi-source failover with concurrent sources${NC}"
    echo -e "${YELLOW}Mode: $mode, Ingestion: $ingest_mode${NC}"
    echo -e "${YELLOW}You should see ONE window that seamlessly switches content${NC}"
    echo ""
    
    # Check binaries
    if [ ! -f "$FFMPEG_PATH" ]; then
        echo -e "${RED}Error: Custom FFmpeg with MSwitch not found at $FFMPEG_PATH${NC}"
        echo -e "${YELLOW}Make sure you've built FFmpeg with MSwitch support${NC}"
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
    
    # Check for curl (needed for webhook control)
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}Error: curl is required for webhook control${NC}"
        exit 1
    fi
    
    # Generate concurrent input sources
    generate_mswitch_sources
    
    # Start MSwitch with real multi-source support
    start_mswitch "$mode" "$ingest_mode"
    
    # Demonstrate failover using webhook commands
    demonstrate_failover $MSWITCH_PID
    
    # Final cleanup (MSwitch process)
    kill $MSWITCH_PID 2>/dev/null || true
}

# Function to test different modes
test_all_modes() {
    echo -e "${CYAN}Testing all MSwitch modes...${NC}"
    
    echo -e "\n${YELLOW}1. Testing GRACEFUL mode with HOT ingestion${NC}"
    main graceful hot
    sleep 5
    
    echo -e "\n${YELLOW}2. Testing SEAMLESS mode with HOT ingestion${NC}"
    main seamless hot
    sleep 5
    
    echo -e "\n${YELLOW}3. Testing CUTOVER mode with STANDBY ingestion${NC}"
    main cutover standby
}

# Parse command line arguments and run
case "${1:-default}" in
    "all"|"test-all")
        test_all_modes
        ;;
    "seamless"|"graceful"|"cutover")
        main "$1" "${2:-hot}"
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [mode] [ingestion_mode]"
        echo "       $0 all                    # Test all modes"
        echo ""
        echo "Modes: seamless, graceful, cutover (default: graceful)"
        echo "Ingestion: hot, standby (default: hot)"
        echo ""
        echo "Examples:"
        echo "  $0                           # Run with graceful/hot"
        echo "  $0 seamless hot              # Run seamless mode with hot ingestion"
        echo "  $0 cutover standby           # Run cutover mode with standby ingestion"
        echo "  $0 all                       # Test all combinations"
        ;;
    *)
        main "${1:-graceful}" "${2:-hot}"
        ;;
esac
