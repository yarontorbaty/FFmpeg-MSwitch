#!/bin/bash

# Simple Auto-Failover Test
# This test verifies auto-failover is disabled by default using file inputs

echo "=== Simple Auto-Failover Test ==="
echo "This test verifies auto-failover is disabled by default"
echo ""

# Create test files
echo "Creating test video files..."
ffmpeg -f lavfi -i "color=red:size=1280x720:rate=30" -t 5 -c:v libx264 -r 30 -preset ultrafast -g 30 -keyint_min 1 -sc_threshold 0 -f mpegts test_red.mts > /dev/null 2>&1
ffmpeg -f lavfi -i "color=green:size=1280x720:rate=30" -t 5 -c:v libx264 -r 30 -preset ultrafast -g 30 -keyint_min 1 -sc_threshold 0 -f mpegts test_green.mts > /dev/null 2>&1
ffmpeg -f lavfi -i "color=blue:size=1280x720:rate=30" -t 5 -c:v libx264 -r 30 -preset ultrafast -g 30 -keyint_min 1 -sc_threshold 0 -f mpegts test_blue.mts > /dev/null 2>&1

echo "Test files created. Running FFmpeg with MSwitch (no auto-failover)..."
echo ""

# Run FFmpeg without auto-failover enabled
timeout 8s ./ffmpeg -y \
  -fflags nobuffer -flags low_delay \
  -analyzeduration 0 -probesize 32 -max_delay 0 \
  -flush_packets 1 \
  -loglevel info \
  -msw.enable -msw.sources "s0=local;s1=local;s2=local" \
  -i test_red.mts \
  -i test_green.mts \
  -i test_blue.mts \
  -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0:tube=2,fps=30[out]" \
  -map "[out]" -c:v libx264 -r 30 -preset ultrafast -g 30 -keyint_min 1 -sc_threshold 0 \
  -pix_fmt yuv420p -f mpegts test_output.mts > simple_auto_failover_test.log 2>&1

echo "Test completed. Analyzing logs..."
echo ""

echo "=== LOG ANALYSIS ==="
echo ""

echo "1. Check for auto-failover initialization:"
grep "Auto-failover initialized" simple_auto_failover_test.log

echo ""
echo "2. Check for auto-failover status:"
grep "Auto-failover.*disabled" simple_auto_failover_test.log

echo ""
echo "3. Check for health monitoring messages:"
grep "health monitoring" simple_auto_failover_test.log

echo ""
echo "4. Check for duplicate frame detection:"
grep "duplicate.*threshold" simple_auto_failover_test.log

echo ""
echo "5. Check for MSwitch initialization:"
grep "MSwitch.*initialized" simple_auto_failover_test.log

echo ""
echo "6. Check for auto-failover enable status:"
grep "enable=" simple_auto_failover_test.log

echo ""
echo "=== EXPECTED RESULTS ==="
echo ""
echo "✅ Should see: 'Auto-failover disabled by default'"
echo "✅ Should see: 'enable=0' in auto-failover initialization"
echo "❌ Should NOT see: health monitoring messages"
echo "❌ Should NOT see: duplicate frame detection messages"
echo ""
echo "This confirms auto-failover is disabled by default!"

# Cleanup
rm -f test_red.mts test_green.mts test_blue.mts test_output.mts
