#!/bin/bash

# Test two-stage failover: primary → black interim → healthy backup

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Two-Stage Failover Test ===${NC}"
echo ""
echo "Setup:"
echo "  - Source 0 (udp://127.0.0.1:12350) - Primary"
echo "  - Source 1 (udp://127.0.0.1:12351) - Backup 1"
echo "  - Source 2 (udp://127.0.0.1:12352) - Backup 2"
echo "  - Source 3 (black_loop.ts) - Black interim"
echo ""
echo "Failover strategy:"
echo "  1. When source 0 fails → Switch to BLACK (source 3)"
echo "  2. Health monitor looks for healthy backups (1 or 2)"
echo "  3. When found → Switch from BLACK to healthy backup"
echo ""

# Check if black loop file exists
if [ ! -f "black_loop.ts" ]; then
    echo -e "${YELLOW}Creating black loop file...${NC}"
    ./ffmpeg -f lavfi -i color=c=black:s=1280x720:r=30 -t 1 -c:v libx264 \
        -preset ultrafast -g 30 -keyint_min 1 -sc_threshold 0 -pix_fmt yuv420p \
        -f mpegts black_loop.ts -y 2>&1 | tail -3
fi

# Get absolute path for black file
BLACK_FILE="$(pwd)/black_loop.ts"

echo -e "${GREEN}Starting FFmpeg with auto-failover...${NC}"
echo ""
echo "Command:"
echo "./ffmpeg -f mswitchdirect \\"
echo "  -msw_sources \"udp://127.0.0.1:12350,udp://127.0.0.1:12351,udp://127.0.0.1:12352,${BLACK_FILE}\" \\"
echo "  -msw_port 8099 \\"
echo "  -msw_auto_failover 1 \\"
echo "  -i dummy \\"
echo "  -c:v libx264 -r 30 -preset ultrafast -g 60 -keyint_min 1 -sc_threshold 0 -pix_fmt yuv420p \\"
echo "  -f mpegts udp://127.0.0.1:12360?pkt_size=1316"
echo ""
echo -e "${YELLOW}Controls:${NC}"
echo "  - Press 0-3 to manually switch sources"
echo "  - Press 'm' for status"
echo "  - Stop source 0 to test auto-failover"
echo ""

./ffmpeg -v info -f mswitchdirect \
  -msw_sources "udp://127.0.0.1:12350,udp://127.0.0.1:12351,udp://127.0.0.1:12352,${BLACK_FILE}" \
  -msw_port 8099 \
  -msw_auto_failover 1 \
  -i dummy \
  -c:v libx264 -r 30 -preset ultrafast -g 60 -keyint_min 1 -sc_threshold 0 -pix_fmt yuv420p \
  -f mpegts udp://127.0.0.1:12360?pkt_size=1316

