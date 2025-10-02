#!/bin/bash
# MSwitch Demo with Filter-based Switching
# Uses streamselect filter for visual source switching

set -e

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
MSWITCH_WEBHOOK_PORT=8099

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "======================================================"
echo "  MSwitch Filter-Based Switching Demo"
echo "======================================================"
echo ""

# Cleanup function
cleanup() {
    echo -e "\n${BLUE}Cleaning up processes...${NC}"
    pkill -9 ffmpeg 2>/dev/null || true
    pkill -9 ffplay 2>/dev/null || true
    sleep 1
}

# Setup cleanup on exit
trap cleanup EXIT INT TERM

# Kill any existing FFmpeg processes
cleanup

echo -e "${GREEN}Step 1: Starting source generators...${NC}"
# Start three distinct color sources on UDP
$FFMPEG_PATH -f lavfi -i "color=red:size=320x240:rate=5" \
    -c:v libx264 -preset ultrafast -g 5 -pix_fmt yuv420p -tune zerolatency \
    -f mpegts "udp://127.0.0.1:12346" -loglevel error &
sleep 0.5

$FFMPEG_PATH -f lavfi -i "color=green:size=320x240:rate=5" \
    -c:v libx264 -preset ultrafast -g 5 -pix_fmt yuv420p -tune zerolatency \
    -f mpegts "udp://127.0.0.1:12347" -loglevel error &
sleep 0.5

$FFMPEG_PATH -f lavfi -i "color=blue:size=320x240:rate=5" \
    -c:v libx264 -preset ultrafast -g 5 -pix_fmt yuv420p -tune zerolatency \
    -f mpegts "udp://127.0.0.1:12348" -loglevel error &

echo "Waiting for sources to start..."
sleep 3

echo -e "${GREEN}Step 2: Starting MSwitch with streamselect filter...${NC}"
echo ""
echo "Command structure:"
echo "  - Three inputs: RED, GREEN, BLUE"
echo "  - MSwitch enabled with webhook control"
echo "  - Filter: [0:v][1:v][2:v]streamselect=inputs=3:map=0[out]"
echo "  - Output mapped from filter to ffplay"
echo ""

# Start MSwitch with filter_complex
$FFMPEG_PATH \
    -msw.enable \
    -msw.sources "s0=udp://127.0.0.1:12346;s1=udp://127.0.0.1:12347;s2=udp://127.0.0.1:12348" \
    -msw.ingest hot \
    -msw.mode graceful \
    -msw.buffer_ms 1000 \
    -msw.webhook.enable \
    -msw.webhook.port $MSWITCH_WEBHOOK_PORT \
    -i "udp://127.0.0.1:12346" \
    -i "udp://127.0.0.1:12347" \
    -i "udp://127.0.0.1:12348" \
    -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -g 50 -pix_fmt yuv420p \
    -f mpegts - 2>&1 | ffplay -i - -loglevel warning &

MSWITCH_PID=$!
echo "MSwitch started (PID: $MSWITCH_PID)"
echo ""
echo "Waiting for MSwitch to initialize..."
sleep 5

echo -e "${GREEN}Step 3: Testing filter-based switching...${NC}"
echo ""
echo "=================================="
echo "Initial source should be 0 (RED)"
echo ""
echo -e "${BLUE}Press Enter to switch to source 1 (GREEN)...${NC}"
read

echo -e "${GREEN}Switching to source 1 (GREEN)...${NC}"
curl -s -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \
    -H "Content-Type: application/json" \
    -d '{"source":"s1"}' || echo "  WARNING: Webhook request failed"
echo ""
echo -e "${BLUE}Press Enter to switch to source 2 (BLUE)...${NC}"
read

echo -e "${GREEN}Switching to source 2 (BLUE)...${NC}"
curl -s -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \
    -H "Content-Type: application/json" \
    -d '{"source":"s2"}' || echo "  WARNING: Webhook request failed"
echo ""
echo -e "${BLUE}Press Enter to switch back to source 0 (RED)...${NC}"
read

echo -e "${GREEN}Switching back to source 0 (RED)...${NC}"
curl -s -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \
    -H "Content-Type: application/json" \
    -d '{"source":"s0"}' || echo "  WARNING: Webhook request failed"
echo ""
echo "=================================="

echo ""
echo -e "${BLUE}Demo running. Try these commands in another terminal:${NC}"
echo ""
echo "  # Switch to source 1 (GREEN):"
echo "  curl -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \\"
echo "       -H 'Content-Type: application/json' -d '{\"source\":\"s1\"}'"
echo ""
echo "  # Switch to source 2 (BLUE):"
echo "  curl -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \\"
echo "       -H 'Content-Type: application/json' -d '{\"source\":\"s2\"}'"
echo ""
echo "  # Switch to source 0 (RED):"
echo "  curl -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \\"
echo "       -H 'Content-Type: application/json' -d '{\"source\":\"s0\"}'"
echo ""
echo -e "${RED}Press Ctrl+C to stop${NC}"
echo ""

# Wait for user to stop
wait $MSWITCH_PID

