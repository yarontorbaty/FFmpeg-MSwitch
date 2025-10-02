#!/bin/bash
# Visual Test for Filter-Based MSwitch
# Shows RED, GREEN, BLUE switching in ffplay

set -e

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
FFPLAY_PATH="${FFPLAY_PATH:-ffplay}"
MSWITCH_WEBHOOK_PORT=8099

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "======================================================"
echo "  MSwitch Filter-Based Visual Switching Test"
echo "======================================================"

cleanup() {
    echo -e "\n${BLUE}Cleaning up...${NC}"
    pkill -9 ffmpeg 2>/dev/null || true
    pkill -9 ffplay 2>/dev/null || true
    sleep 1
}

trap cleanup EXIT INT TERM
cleanup

echo -e "${GREEN}Starting MSwitch with filter-based switching...${NC}"
echo ""
echo "This will open ffplay showing:"
echo "  - Initial: RED (source 0)"
echo "  - You can switch sources using curl commands"
echo ""

# Start FFmpeg with MSwitch and streamselect filter, output to ffplay
$FFMPEG_PATH \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local" \
    -msw.ingest hot \
    -msw.mode graceful \
    -msw.webhook.enable \
    -msw.webhook.port $MSWITCH_WEBHOOK_PORT \
    -f lavfi -i "color=red:size=640x480:rate=10" \
    -f lavfi -i "color=green:size=640x480:rate=10" \
    -f lavfi -i "color=blue:size=640x480:rate=10" \
    -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -g 50 -pix_fmt yuv420p \
    -f mpegts - 2>&1 | $FFPLAY_PATH -i - -loglevel warning &

FFMPEG_PID=$!

echo "Waiting for initialization..."
sleep 5

echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${GREEN}Initial state: RED (source 0)${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo -e "${BLUE}Press Enter to switch to GREEN (source 1)...${NC}"
read

echo -e "${GREEN}→ Switching to source 1 (GREEN)...${NC}"
curl -s -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \
    -H "Content-Type: application/json" \
    -d '{"source":"s1"}' && echo " ✓" || echo " ✗ Failed"
sleep 2

echo ""
echo -e "${BLUE}Press Enter to switch to BLUE (source 2)...${NC}"
read

echo -e "${GREEN}→ Switching to source 2 (BLUE)...${NC}"
curl -s -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \
    -H "Content-Type: application/json" \
    -d '{"source":"s2"}' && echo " ✓" || echo " ✗ Failed"
sleep 2

echo ""
echo -e "${BLUE}Press Enter to switch back to RED (source 0)...${NC}"
read

echo -e "${GREEN}→ Switching back to source 0 (RED)...${NC}"
curl -s -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \
    -H "Content-Type: application/json" \
    -d '{"source":"s0"}' && echo " ✓" || echo " ✗ Failed"

echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${GREEN}Manual commands available:${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo "  Switch to GREEN:"
echo "    curl -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \\"
echo "         -H 'Content-Type: application/json' -d '{\"source\":\"s1\"}'"
echo ""
echo "  Switch to BLUE:"
echo "    curl -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \\"
echo "         -H 'Content-Type: application/json' -d '{\"source\":\"s2\"}'"
echo ""
echo "  Switch to RED:"
echo "    curl -X POST http://localhost:$MSWITCH_WEBHOOK_PORT/switch \\"
echo "         -H 'Content-Type: application/json' -d '{\"source\":\"s0\"}'"
echo ""
echo -e "${RED}Press Ctrl+C to stop${NC}"

wait $FFMPEG_PID

