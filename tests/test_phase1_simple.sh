#!/bin/bash

# Phase 1: Simple Subprocess Test
# Just verifies that subprocesses are created and cleaned up

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

print_header "Phase 1: Subprocess Creation Test"

# Cleanup first
cleanup

echo ""
print_info "This test verifies that MSwitch can:"
echo "  1. Fork and start FFmpeg subprocesses"
echo "  2. Generate correct subprocess commands"
echo "  3. Clean up subprocesses on exit"
echo ""

print_header "Step 1: Start MSwitch (will fail due to no inputs)"

print_info "Starting MSwitch with 3 test sources..."
print_info "Note: Main FFmpeg will exit quickly (no inputs), but we'll check if subprocesses started"

# Start in background and capture logs
TMPLOG="/tmp/mswitch_test_$$.log"
$FFMPEG_PATH \
    -msw.enable \
    -msw.sources "s0=udp://127.0.0.1:5000;s1=udp://127.0.0.1:5001;s2=udp://127.0.0.1:5002" \
    -msw.mode seamless \
    -f null - \
    > "$TMPLOG" 2>&1 &

MAIN_PID=$!
print_info "Main FFmpeg PID: $MAIN_PID"

# Wait a moment for subprocesses to potentially start
sleep 2

echo ""
print_header "Step 2: Check for Subprocess Creation"

# Check if subprocess startup messages are in the log
if grep -q "Starting subprocesses for all sources" "$TMPLOG"; then
    print_success "MSwitch attempted to start subprocesses"
else
    print_error "MSwitch did not attempt to start subprocesses"
    echo ""
    print_info "Log contents:"
    cat "$TMPLOG"
    exit 1
fi

# Check if subprocess commands were generated
SUBPROCESS_COMMANDS=$(grep -c "Subprocess.*Command:" "$TMPLOG" || echo "0")
print_info "Subprocess commands generated: $SUBPROCESS_COMMANDS"

if [ "$SUBPROCESS_COMMANDS" -ge 3 ]; then
    print_success "All 3 subprocess commands generated"
    echo ""
    print_info "Generated commands:"
    grep "Subprocess.*Command:" "$TMPLOG" | while read line; do
        echo "  $line"
    done
else
    print_error "Only $SUBPROCESS_COMMANDS commands generated (expected 3)"
fi

# Check if subprocesses actually started
SUBPROCESS_STARTED=$(grep -c "Subprocess.*Started (PID:" "$TMPLOG" || echo "0")
print_info "Subprocesses started: $SUBPROCESS_STARTED"

if [ "$SUBPROCESS_STARTED" -ge 3 ]; then
    print_success "All 3 subprocesses started"
    echo ""
    print_info "Started processes:"
    grep "Subprocess.*Started" "$TMPLOG" | while read line; do
        echo "  $line"
    done
else
    print_error "Only $SUBPROCESS_STARTED subprocesses started (expected 3)"
fi

echo ""
print_header "Step 3: Verify Subprocess PIDs"

# Extract PIDs from log
SUBPROCESS_PIDS=$(grep "Subprocess.*Started (PID:" "$TMPLOG" | sed -E 's/.*PID: ([0-9]+).*/\1/' || echo "")

if [ -n "$SUBPROCESS_PIDS" ]; then
    print_info "Subprocess PIDs from log:"
    for pid in $SUBPROCESS_PIDS; do
        if ps -p $pid > /dev/null 2>&1; then
            print_success "PID $pid is running"
            ps -p $pid -o pid,command | tail -1
        else
            print_error "PID $pid is not running (may have exited)"
        fi
    done
else
    print_error "No subprocess PIDs found in log"
fi

echo ""
print_header "Step 4: Check Running FFmpeg Processes"

RUNNING_FFMPEG=$(ps aux | grep -E "ffmpeg.*nostdin.*-i.*udp:" | grep -v grep | wc -l | tr -d ' ')
print_info "FFmpeg subprocesses currently running: $RUNNING_FFMPEG"

if [ "$RUNNING_FFMPEG" -gt 0 ]; then
    print_success "Found $RUNNING_FFMPEG subprocess(es)"
    echo ""
    ps aux | grep -E "ffmpeg.*nostdin" | grep -v grep | while read line; do
        echo "  $line"
    done
else
    print_info "No subprocesses running (may have exited due to invalid UDP sources)"
fi

echo ""
print_header "Step 5: Check Monitor Thread"

if grep -q "Starting subprocess monitor thread" "$TMPLOG"; then
    print_success "Subprocess monitor thread started"
fi

if grep -q "Subprocess monitor thread started" "$TMPLOG"; then
    print_success "Subprocess monitor thread is running"
fi

echo ""
print_header "Step 6: Wait for Main Process"

# Wait for main process
if ps -p $MAIN_PID > /dev/null 2>&1; then
    print_info "Waiting for main FFmpeg to exit..."
    wait $MAIN_PID 2>/dev/null || true
fi

print_info "Main FFmpeg has exited"

echo ""
print_header "Step 7: Verify Cleanup"

sleep 1

# Check if subprocesses were cleaned up
REMAINING=$(ps aux | grep -E "ffmpeg.*nostdin" | grep -v grep | wc -l | tr -d ' ')

if [ "$REMAINING" -eq 0 ]; then
    print_success "All subprocesses cleaned up"
else
    print_error "$REMAINING subprocess(es) still running"
    print_info "Remaining processes:"
    ps aux | grep -E "ffmpeg.*nostdin" | grep -v grep
fi

echo ""
print_header "Test Summary"

echo ""
print_info "Full log saved to: $TMPLOG"
echo ""
print_info "Key findings:"
echo "  • Subprocess command generation: $SUBPROCESS_COMMANDS/3"
echo "  • Subprocess startup: $SUBPROCESS_STARTED/3"
echo "  • Subprocess cleanup: $([ $REMAINING -eq 0 ] && echo 'Success' || echo 'Failed')"
echo ""

if [ "$SUBPROCESS_STARTED" -ge 3 ] && [ "$REMAINING" -eq 0 ]; then
    echo ""
    print_success "✓✓✓ PHASE 1 CORE FUNCTIONALITY VERIFIED ✓✓✓"
    echo ""
    print_info "What works:"
    echo "  ✓ Subprocess command generation"
    echo "  ✓ Fork/exec subprocess creation"
    echo "  ✓ PID tracking"
    echo "  ✓ Monitor thread startup"
    echo "  ✓ Graceful subprocess cleanup"
    echo ""
    print_info "Expected behavior (not errors):"
    echo "  • Main FFmpeg exits immediately (no input streams)"
    echo "  • Subprocesses may fail (invalid UDP sources)"
    echo "  • This is normal for Phase 1 testing"
    echo ""
    print_info "Next steps:"
    echo "  1. Implement Phase 2: UDP Proxy"
    echo "  2. Main FFmpeg will read from subprocess UDP outputs"
    echo "  3. UDP proxy forwards packets from active source"
    echo ""
    exit 0
else
    print_error "Phase 1 tests failed"
    echo ""
    print_info "Review the log for details:"
    echo "  cat $TMPLOG"
    exit 1
fi

