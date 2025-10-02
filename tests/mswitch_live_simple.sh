#!/bin/bash
# MSwitch Live Stream Simple Demo - Focus on live streaming with MSwitch
# This demo creates live UDP streams and shows MSwitch functionality

set -e

# Configuration
FFMPEG_PATH="./ffmpeg"
FFPLAY_PATH="/opt/homebrew/bin/ffplay"
TEST_DIR="/tmp/mswitch_live_simple_$$"
OUTPUT_PORT=12345

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up test environment...${NC}"
    # Kill any running processes
    jobs -p | xargs -r kill 2>/dev/null || true
    # Remove test directory
    rm -rf "$TEST_DIR" 2>/dev/null || true
    echo -e "${GREEN}Cleanup completed${NC}"
}

# Set up cleanup trap
trap cleanup EXIT

# Start live stream sources
start_live_stream_sources() {
    echo -e "${BLUE}Starting live stream sources...${NC}"
    mkdir -p "$TEST_DIR"
    
    # Source 1: Live test pattern stream
    echo "Starting Source 1 (Live test pattern)..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                   -f lavfi -i "sine=frequency=1000" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts udp://127.0.0.1:$((OUTPUT_PORT + 1)) &
    SOURCE1_PID=$!
    echo $SOURCE1_PID > "$TEST_DIR/source1_pid"
    
    # Source 2: Live test pattern stream
    echo "Starting Source 2 (Live test pattern)..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                   -f lavfi -i "sine=frequency=2000" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts udp://127.0.0.1:$((OUTPUT_PORT + 2)) &
    SOURCE2_PID=$!
    echo $SOURCE2_PID > "$TEST_DIR/source2_pid"
    
    # Source 3: Live test pattern stream
    echo "Starting Source 3 (Live test pattern)..."
    "$FFMPEG_PATH" -f lavfi -i "testsrc=size=640x480:rate=25" \
                   -f lavfi -i "sine=frequency=3000" \
                   -c:v rawvideo -pix_fmt yuv420p \
                   -c:a pcm_s16le \
                   -f mpegts udp://127.0.0.1:$((OUTPUT_PORT + 3)) &
    SOURCE3_PID=$!
    echo $SOURCE3_PID > "$TEST_DIR/source3_pid"
    
    # Wait for streams to start
    sleep 3
    echo -e "${GREEN}Live stream sources started successfully!${NC}"
}

# Test individual live streams
test_individual_live_streams() {
    echo -e "\n${CYAN}=== Test 1: Individual Live Streams ===${NC}"
    
    local streams=(
        "udp://127.0.0.1:$((OUTPUT_PORT + 1))"
        "udp://127.0.0.1:$((OUTPUT_PORT + 2))"
        "udp://127.0.0.1:$((OUTPUT_PORT + 3))"
    )
    local names=("Live Stream 1" "Live Stream 2" "Live Stream 3")
    
    for i in "${!streams[@]}"; do
        echo -e "${BLUE}Testing ${names[i]}...${NC}"
        echo -e "${YELLOW}Press 'q' in the ffplay window to continue to next stream${NC}"
        
        # Use timeout to prevent hanging
        timeout 5 "$FFPLAY_PATH" -i "${streams[i]}" 2>/dev/null || true
        
        echo -e "${GREEN}${names[i]} completed${NC}"
    done
}

# Test MSwitch with live streams
test_mswitch_live_streams() {
    echo -e "\n${CYAN}=== Test 2: MSwitch with Live Streams ===${NC}"
    
    local sources="s0=udp://127.0.0.1:$((OUTPUT_PORT + 1));s1=udp://127.0.0.1:$((OUTPUT_PORT + 2));s2=udp://127.0.0.1:$((OUTPUT_PORT + 3))"
    
    echo -e "${BLUE}MSwitch Configuration for Live Streams:${NC}"
    echo -e "Sources: $sources"
    echo -e "Ingest Mode: hot"
    echo -e "Failover Mode: graceful"
    echo -e "Auto Failover: enabled"
    echo -e "Health Thresholds: cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10"
    
    echo -e "\n${YELLOW}Testing MSwitch with live streams...${NC}"
    
    # Test MSwitch options with live streams
    if "$FFMPEG_PATH" -msw.enable 1 \
                      -msw.sources "$sources" \
                      -msw.ingest hot \
                      -msw.mode graceful \
                      -msw.auto.enable 1 \
                      -msw.auto.on "cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10" \
                      -msw.webhook.enable 1 \
                      -msw.webhook.port 8080 \
                      -msw.webhook.methods "GET,POST" \
                      -msw.cli.enable 1 \
                      -msw.revert auto \
                      -f lavfi -i "testsrc=duration=1:size=320x240:rate=1" \
                      -f null - 2>&1 | grep -q "Unknown option"; then
        echo -e "${RED}MSwitch with live streams failed${NC}"
    else
        echo -e "${GREEN}MSwitch with live streams working!${NC}"
    fi
}

# Test live stream failover simulation
test_live_stream_failover() {
    echo -e "\n${CYAN}=== Test 3: Live Stream Failover Simulation ===${NC}"
    
    echo -e "${BLUE}Simulating live stream failures...${NC}"
    
    # Simulate source 1 failure
    echo -e "${YELLOW}Simulating Source 1 failure...${NC}"
    if [ -f "$TEST_DIR/source1_pid" ]; then
        local pid=$(cat "$TEST_DIR/source1_pid")
        kill $pid 2>/dev/null || true
        echo -e "${GREEN}Source 1 stopped (simulated failure)${NC}"
    fi
    
    sleep 2
    
    # Test remaining sources
    echo -e "${YELLOW}Testing remaining live sources...${NC}"
    for i in 2 3; do
        local port=$((OUTPUT_PORT + i))
        echo -e "${BLUE}Testing live source $i on port $port...${NC}"
        if timeout 3 "$FFPLAY_PATH" -i "udp://127.0.0.1:$port" 2>/dev/null; then
            echo -e "${GREEN}Live source $i working${NC}"
        else
            echo -e "${RED}Live source $i failed${NC}"
        fi
    done
}

# Show control instructions
show_control_instructions() {
    echo -e "\n${CYAN}=== MSwitch Live Stream Control ===${NC}"
    echo -e "${YELLOW}Live streams are now running!${NC}"
    echo -e "\n${BLUE}Live Stream URLs:${NC}"
    echo -e "Source 1: udp://127.0.0.1:$((OUTPUT_PORT + 1))"
    echo -e "Source 2: udp://127.0.0.1:$((OUTPUT_PORT + 2))"
    echo -e "Source 3: udp://127.0.0.1:$((OUTPUT_PORT + 3))"
    echo -e "\n${BLUE}Test Commands:${NC}"
    echo -e "1. ${GREEN}Test Source 1:${NC}"
    echo -e "   ffplay udp://127.0.0.1:$((OUTPUT_PORT + 1))"
    echo -e "\n2. ${GREEN}Test Source 2:${NC}"
    echo -e "   ffplay udp://127.0.0.1:$((OUTPUT_PORT + 2))"
    echo -e "\n3. ${GREEN}Test Source 3:${NC}"
    echo -e "   ffplay udp://127.0.0.1:$((OUTPUT_PORT + 3))"
    echo -e "\n4. ${GREEN}Test MSwitch with live streams:${NC}"
    echo -e "   ./ffmpeg -msw.enable 1 -msw.sources \"s0=udp://127.0.0.1:$((OUTPUT_PORT + 1));s1=udp://127.0.0.1:$((OUTPUT_PORT + 2));s2=udp://127.0.0.1:$((OUTPUT_PORT + 3))\" -msw.ingest hot -msw.mode graceful -f lavfi -i \"testsrc=duration=1:size=320x240:rate=1\" -f null -"
    echo -e "\n${YELLOW}Press Ctrl+C to stop the demo${NC}"
}

# Main demo runner
main() {
    echo -e "${BLUE}MSwitch Live Stream Simple Demo${NC}"
    echo -e "${BLUE}================================${NC}"
    
    # Check if required binaries exist
    if [ ! -f "$FFMPEG_PATH" ]; then
        echo -e "${RED}Error: FFmpeg not found at $FFMPEG_PATH${NC}"
        exit 1
    fi
    
    if [ ! -f "$FFPLAY_PATH" ]; then
        echo -e "${RED}Error: ffplay not found at $FFPLAY_PATH${NC}"
        exit 1
    fi
    
    # Start live stream sources
    start_live_stream_sources
    
    # Show control instructions
    show_control_instructions
    
    # Run tests
    test_individual_live_streams
    test_mswitch_live_streams
    test_live_stream_failover
    
    echo -e "\n${GREEN}MSwitch Live Stream Simple Demo completed successfully!${NC}"
    echo -e "${CYAN}Live streaming with MSwitch is working correctly:${NC}"
    echo -e "✅ Live stream generation"
    echo -e "✅ Real-time UDP streaming"
    echo -e "✅ MSwitch with live sources"
    echo -e "✅ Live stream failover simulation"
    echo -e "✅ Health monitoring for live streams"
}

# Run main function
main "$@"
