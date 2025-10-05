#!/bin/bash

# Test MSwitch with SPS/PPS on every I-frame for clean VLC recovery

echo "🧪 Testing MSwitch with SPS/PPS on every I-frame..."
echo ""
echo "This test will:"
echo "1. Start FFmpeg with -x264-params repeat-headers=1"
echo "2. This forces SPS/PPS to be sent with every I-frame"
echo "3. VLC should recover cleanly after switches"
echo ""
echo "Press Ctrl+C to stop"
echo ""

cd /Users/yarontorbaty/Documents/Code/FFmpeg

# Kill any existing FFmpeg processes
pkill -9 ffmpeg 2>/dev/null
sleep 1

# Run FFmpeg with repeat-headers to include SPS/PPS with every I-frame
./ffmpeg -y -v info \
  -f mswitchdirect \
  -msw_sources "udp://127.0.0.1:12350,udp://127.0.0.1:12351,udp://127.0.0.1:12352" \
  -msw_port 8099 \
  -msw_auto_failover 1 \
  -msw_health_interval 100 \
  -msw_source_timeout 1000 \
  -msw_grace_period 2000 \
  -msw_reconnect_timeout 0 \
  -i dummy \
  -c:v libx264 \
  -r 30 \
  -preset ultrafast \
  -g 60 \
  -keyint_min 1 \
  -sc_threshold 0 \
  -x264-params repeat-headers=1 \
  -pix_fmt yuv420p \
  -f mpegts "udp://127.0.0.1:12360?pkt_size=1316"
