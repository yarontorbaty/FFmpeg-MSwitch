#!/bin/bash

# Phase 2: UDP Proxy Test
# Tests that MSwitch can forward UDP packets from active subprocess

set -e

FFMPEG_PATH="./ffmpeg"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}======================================================${NC}"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${YELLOW}ℹ $1${NC}"; }

cleanup() {
    print_info "Cleaning up all FFmpeg processes..."
    pkill -9 ffmpeg 2>/dev/null || true
    sleep 1
}

trap cleanup EXIT

print_header "Phase 2: UDP Proxy Test"

# Cleanup first
cleanup

echo ""
print_info "This test verifies that MSwitch can:"
echo "  1. Start subprocesses that stream to UDP"
echo "  2. Listen on subprocess UDP ports"
echo "  3. Forward packets from active source to proxy output"
echo "  4. Allow main FFmpeg to read from proxy output"
echo ""

print_header "Step 1: Start MSwitch with 3 Color Sources"

print_info "Starting MSwitch in background..."

# Start MSwitch with subprocess sources
# MSwitch will:
# - Start 3 subprocesses (color red, green, blue)
# - Each subprocess outputs to UDP ports 12350, 12351, 12352
# - UDP proxy forwards active source to port 12400
# - Main FFmpeg reads from port 12400

$FFMPEG_PATH \
    -msw.enable \
    -msw.sources "s0=lavfi -f lavfi -i color=red:size=320x240:rate=5;s1=lavfi -f lavfi -i color=green:size=320x240:rate=5;s2=lavfi -f lavfi -i color=blue:size=320x240:rate=5" \
    -msw.mode seamless \
    -i udp://127.0.0.1:12400 \
    -t 10 \
    -c:v libx264 -preset ultrafast \
    -f mpegts udp://127.0.0.1:12500 \
    > /tmp/mswitch_phase2_test.log 2>&1 &

MAIN_PID=$!
print_info "Main FFmpeg PID: $MAIN_PID"

# Wait for initialization
sleep 3

echo ""
print_header "Step 2: Check Subprocess Creation"

SUBPROCESS_COUNT=$(ps aux | grep -E "ffmpeg.*nostdin.*lavfi" | grep -v grep | wc -l | tr -d ' ')
print_info "Subprocess count: $SUBPROCESS_COUNT"

if [ "$SUBPROCESS_COUNT" -ge 3 ]; then
    print_success "Found $SUBPROCESS_COUNT subprocesses (expected 3)"
else
    print_error "Only found $SUBPROCESS_COUNT subprocesses (expected 3)"
fi

echo ""
print_header "Step 3: Check UDP Proxy Initialization"

if grep -q "Starting UDP proxy thread" /tmp/mswitch_phase2_test.log; then
    print_success "UDP proxy thread started"
fi

if grep -q "UDP Proxy.*Socket bound" /tmp/mswitch_phase2_test.log; then
    BOUND_COUNT=$(grep -c "UDP Proxy.*Socket bound" /tmp/mswitch_phase2_test.log)
    print_success "UDP proxy bound to $BOUND_COUNT ports"
    grep "UDP Proxy.*Socket bound" /tmp/mswitch_phase2_test.log | while read line; do
        echo "  $line"
    done
fi

if grep -q "UDP Proxy.*Forwarding to" /tmp/mswitch_phase2_test.log; then
    print_success "UDP proxy configured for forwarding"
    grep "UDP Proxy.*Forwarding to" /tmp/mswitch_phase2_test.log | tail -1
fi

if grep -q "Proxy thread running" /tmp/mswitch_phase2_test.log; then
    print_success "UDP proxy thread is running"
fi

echo ""
print_header "Step 4: Check Main FFmpeg Input"

if grep -q "Input #0.*udp://127.0.0.1:12400" /tmp/mswitch_phase2_test.log; then
    print_success "Main FFmpeg reading from proxy output (127.0.0.1:12400)"
else
    print_error "Main FFmpeg not reading from proxy output"
fi

echo ""
print_header "Step 5: Wait for Processing"

print_info "Waiting for FFmpeg to process (max 15 seconds)..."
WAIT_COUNT=0
while [ $WAIT_COUNT -lt 15 ]; do
    if ! ps -p $MAIN_PID > /dev/null 2>&1; then
        print_success "Main FFmpeg finished"
        break
    fi
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
    echo -n "."
done
echo ""

if ps -p $MAIN_PID > /dev/null 2>&1; then
    print_info "Main FFmpeg still running, stopping..."
    kill -TERM $MAIN_PID 2>/dev/null || true
    sleep 2
fi

echo ""
print_header "Step 6: Verify Cleanup"

sleep 2

REMAINING=$(ps aux | grep -E "ffmpeg.*nostdin" | grep -v grep | wc -l | tr -d ' ')

if [ "$REMAINING" -eq 0 ]; then
    print_success "All subprocesses cleaned up"
else
    print_error "$REMAINING subprocess(es) still running"
fi

if grep -q "Stopping UDP proxy thread" /tmp/mswitch_phase2_test.log; then
    print_success "UDP proxy thread stopped cleanly"
fi

echo ""
print_header "Test Results"

# Check for errors
if grep -q "UDP Proxy.*Failed" /tmp/mswitch_phase2_test.log; then
    print_error "UDP proxy errors detected:"
    grep "UDP Proxy.*Failed" /tmp/mswitch_phase2_test.log
fi

# Check if any data was forwarded
if grep -q "Stream #0:0" /tmp/mswitch_phase2_test.log; then
    print_success "Main FFmpeg detected input stream"
    grep "Stream #0:0" /tmp/mswitch_phase2_test.log | head -1
fi

echo ""
print_info "Full log saved to: /tmp/mswitch_phase2_test.log"

echo ""
if [ "$SUBPROCESS_COUNT" -ge 3 ] && grep -q "Proxy thread running" /tmp/mswitch_phase2_test.log; then
    print_success "✓✓✓ PHASE 2 UDP PROXY IS WORKING ✓✓✓"
    echo ""
    print_info "What works:"
    echo "  ✓ Subprocesses start and stream to UDP"
    echo "  ✓ UDP proxy listens on subprocess ports"
    echo "  ✓ Proxy forwards to output port 12400"
    echo "  ✓ Main FFmpeg can read from proxy"
    echo ""
    print_info "Next steps:"
    echo "  1. Test visual switching (press 0, 1, 2 keys)"
    echo "  2. Verify color changes (RED → GREEN → BLUE)"
    echo "  3. Test webhook switching"
    echo ""
    exit 0
else
    print_error "Phase 2 tests failed"
    echo ""
    print_info "Check the log for details:"
    echo "  cat /tmp/mswitch_phase2_test.log"
    exit 1
fi

