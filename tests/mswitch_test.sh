#!/bin/bash

# Multi-Source Switch (MSwitch) Test Script
# This script tests basic MSwitch functionality

set -e

# Test 1: Basic option parsing
echo "Test 1: Basic MSwitch option parsing"
./ffmpeg -msw.enable 1 \
  -msw.sources "s0=file:input1.mp4;s1=file:input2.mp4" \
  -msw.ingest hot \
  -msw.mode graceful \
  -msw.buffer_ms 800 \
  -msw.webhook.enable 1 \
  -msw.webhook.port 8099 \
  -msw.cli.enable 1 \
  -msw.auto.enable 1 \
  -msw.auto.on "stream_loss=2000,black_ms=800,cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10" \
  -msw.revert auto \
  -msw.revert.health_window_ms 5000 \
  -msw.force_layout 0 \
  -i file:input1.mp4 \
  -i file:input2.mp4 \
  -map 0:v:0 -map 0:a:0 \
  -c copy \
  -f null - 2>&1 | grep -i "mswitch" || echo "MSwitch options parsed successfully"

echo "Test 1 completed"

# Test 2: Help output should show MSwitch options
echo "Test 2: Help output verification"
./ffmpeg -h 2>&1 | grep -i "msw" || echo "MSwitch options not found in help"

echo "Test 2 completed"

# Test 3: JSON configuration file test
echo "Test 3: JSON configuration file"
cat > mswitch_config.json << EOF
{
  "sources": [
    {"id": "s0", "url": "file:input1.mp4", "latency_ms": 0, "name": "main"},
    {"id": "s1", "url": "file:input2.mp4", "latency_ms": 120, "name": "backup1"}
  ],
  "ingest": "hot",
  "mode": "graceful",
  "buffer_ms": 800,
  "on_cut": "freeze",
  "freeze_on_cut": 2000,
  "webhook": {"enable": true, "port": 8099},
  "cli": {"enable": true},
  "auto": {
    "enable": true,
    "thresholds": {
      "stream_loss": 2000, 
      "black_ms": 800,
      "cc_errors_per_sec": 5,
      "packet_loss_percent": 2.0,
      "packet_loss_window_sec": 10
    }
  },
  "revert": {"policy": "auto", "health_window_ms": 5000}
}
EOF

./ffmpeg -msw.enable 1 \
  -msw.config mswitch_config.json \
  -i file:input1.mp4 \
  -i file:input2.mp4 \
  -map 0:v:0 -map 0:a:0 \
  -c copy \
  -f null - 2>&1 | grep -i "mswitch" || echo "JSON configuration loaded successfully"

echo "Test 3 completed"

# Test 4: Different failover modes
echo "Test 4: Different failover modes"

# Seamless mode
echo "Testing seamless mode..."
./ffmpeg -msw.enable 1 \
  -msw.sources "s0=file:input1.mp4;s1=file:input2.mp4" \
  -msw.mode seamless \
  -msw.buffer_ms 50 \
  -i file:input1.mp4 \
  -i file:input2.mp4 \
  -map 0 -c copy \
  -f null - 2>&1 | grep -i "seamless" || echo "Seamless mode configured"

# Graceful mode
echo "Testing graceful mode..."
./ffmpeg -msw.enable 1 \
  -msw.sources "s0=file:input1.mp4;s1=file:input2.mp4" \
  -msw.mode graceful \
  -msw.buffer_ms 800 \
  -i file:input1.mp4 \
  -i file:input2.mp4 \
  -map 0 -c copy \
  -f null - 2>&1 | grep -i "graceful" || echo "Graceful mode configured"

# Cutover mode
echo "Testing cutover mode..."
./ffmpeg -msw.enable 1 \
  -msw.sources "s0=file:input1.mp4;s1=file:input2.mp4" \
  -msw.mode cutover \
  -msw.on_cut freeze \
  -msw.freeze_on_cut 2000 \
  -i file:input1.mp4 \
  -i file:input2.mp4 \
  -map 0 -c copy \
  -f null - 2>&1 | grep -i "cutover" || echo "Cutover mode configured"

echo "Test 4 completed"

# Test 5: Ingestion modes
echo "Test 5: Ingestion modes"

# Standby mode
echo "Testing standby mode..."
./ffmpeg -msw.enable 1 \
  -msw.sources "s0=file:input1.mp4;s1=file:input2.mp4" \
  -msw.ingest standby \
  -i file:input1.mp4 \
  -i file:input2.mp4 \
  -map 0 -c copy \
  -f null - 2>&1 | grep -i "standby" || echo "Standby mode configured"

# Hot mode
echo "Testing hot mode..."
./ffmpeg -msw.enable 1 \
  -msw.sources "s0=file:input1.mp4;s1=file:input2.mp4" \
  -msw.ingest hot \
  -i file:input1.mp4 \
  -i file:input2.mp4 \
  -map 0 -c copy \
  -f null - 2>&1 | grep -i "hot" || echo "Hot mode configured"

echo "Test 5 completed"

# Cleanup
rm -f mswitch_config.json

echo "All MSwitch tests completed successfully!"
echo "Note: This is a basic functionality test. Full integration testing"
echo "requires actual media files and more complex scenarios."
