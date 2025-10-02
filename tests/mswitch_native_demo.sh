#!/bin/bash
# MSwitch Native Demo - Uses FFmpeg's native multi-input with frame-level switching
# This demo shows MSwitch operating entirely within FFmpeg's pipeline

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
    pkill -f "ffplay" 2>/dev/null || true
    sleep 1
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

cleanup_existing_processes

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}  MSwitch Native Multi-Source Switching Demo${NC}"
echo -e "${CYAN}====================================================${NC}"
echo ""
echo -e "${GREEN}This demo shows MSwitch using FFmpeg's native pipeline:${NC}"
echo -e "  - ${YELLOW}Three color sources:${NC} red, green, blue"
echo -e "  - ${YELLOW}All decoded in parallel${NC} within single FFmpeg process"
echo -e "  - ${YELLOW}Frame-level switching${NC} at the scheduler level"
echo ""
echo -e "${CYAN}Interactive commands:${NC}"
echo -e "  ${YELLOW}0${NC} - Switch to source 0 (red)"
echo -e "  ${YELLOW}1${NC} - Switch to source 1 (green)"
echo -e "  ${YELLOW}2${NC} - Switch to source 2 (blue)"
echo -e "  ${YELLOW}m${NC} - Show MSwitch status"
echo -e "  ${YELLOW}q${NC} - Quit"
echo ""
echo -e "${CYAN}Starting FFmpeg with MSwitch...${NC}"
echo ""

# Run FFmpeg with MSwitch enabled - Native Pipeline Architecture
# All 3 decoders run in parallel, MSwitch filters frames at scheduler level
# Dummy null outputs force decoders 1 and 2 to run
"$FFMPEG_PATH" \
    -loglevel error \
    -msw.enable \
    -msw.sources "s0=red;s1=green;s2=blue" \
    -msw.mode graceful \
    -msw.ingest hot \
    -f lavfi -i "color=red:size=640x480:rate=10" \
    -f lavfi -i "color=green:size=640x480:rate=10" \
    -f lavfi -i "color=blue:size=640x480:rate=10" \
    -map 0:v -c:v libx264 -preset ultrafast -g 10 -pix_fmt yuv420p -f mpegts - \
    -map 1:v -f null - \
    -map 2:v -f null - \
    2>&1 | "$FFPLAY_PATH" -i - &

FFMPEG_PID=$!

echo -e "${GREEN}FFmpeg started (PID: $FFMPEG_PID)${NC}"
echo -e "${CYAN}Watching for process completion...${NC}"
echo ""
echo -e "${YELLOW}Try switching sources:${NC} Type 0, 1, or 2 to switch between colors"
echo ""

# Wait for ffmpeg to finish
wait $FFMPEG_PID

echo -e "${GREEN}Demo completed${NC}"

