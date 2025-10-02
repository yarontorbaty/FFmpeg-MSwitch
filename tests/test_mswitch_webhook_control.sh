#!/bin/bash

# MSwitch Webhook Control Demo
# Use HTTP API to switch sources remotely
# Send curl commands to control the live stream

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
BBB_FILE="/tmp/mswitch_demo/big_buck_bunny.mp4"
WEBHOOK_PORT=8099

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         MSwitch Webhook Control Demo (HTTP API)              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 2

# Check if Big Buck Bunny exists
if [ ! -f "$BBB_FILE" ]; then
    echo "📥 Downloading Big Buck Bunny..."
    mkdir -p /tmp/mswitch_demo
    curl -L -o "$BBB_FILE" "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
    echo ""
fi

echo "Available Sources:"
echo "  [s0] 🔴 Red Color"
echo "  [s1] 🐰 Big Buck Bunny Movie"
echo "  [s2] 🔵 Blue Color"
echo "  [s3] 🟢 Green Color"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  HOW TO USE WEBHOOK CONTROL:"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  The webhook HTTP API runs on port $WEBHOOK_PORT"
echo "  Send POST requests to switch sources:"
echo ""
echo "  Switch to Red:"
echo "    curl -X POST http://localhost:$WEBHOOK_PORT/switch \\
         -H 'Content-Type: application/json' \\
         -d '{\"source\":\"s0\"}'"
echo ""
echo "  Switch to Movie:"
echo "    curl -X POST http://localhost:$WEBHOOK_PORT/switch \\
         -H 'Content-Type: application/json' \\
         -d '{\"source\":\"s1\"}'"
echo ""
echo "  Switch to Blue:"
echo "    curl -X POST http://localhost:$WEBHOOK_PORT/switch \\
         -H 'Content-Type: application/json' \\
         -d '{\"source\":\"s2\"}'"
echo ""
echo "  Switch to Green:"
echo "    curl -X POST http://localhost:$WEBHOOK_PORT/switch \\
         -H 'Content-Type: application/json' \\
         -d '{\"source\":\"s3\"}'"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Starting in 3 seconds..."
echo ""
sleep 3

# Start ffplay
echo "▶️  Starting playback window..."
"${FFPLAY_PATH:-ffplay}" -i udp://127.0.0.1:12395 \
    -window_title "MSwitch Webhook Control - Use curl to switch" \
    -fflags nobuffer -flags low_delay -framedrop \
    -loglevel warning &

FFPLAY_PID=$!
sleep 2

# Start FFmpeg with MSwitch webhook enabled
echo "▶️  Starting FFmpeg encoder with webhook API..."
"$FFMPEG_PATH" \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local;s3=local" \
    -msw.webhook.enable \
    -msw.webhook.port $WEBHOOK_PORT \
    -f lavfi -i "color=red:size=1280x720:rate=30" \
    -stream_loop -1 -re -i "$BBB_FILE" \
    -f lavfi -i "color=blue:size=1280x720:rate=30" \
    -f lavfi -i "color=green:size=1280x720:rate=30" \
    -map 0:v -map 1:v -map 2:v -map 3:v \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -g 30 -keyint_min 30 -sc_threshold 0 \
    -b:v 4M -maxrate 4M -bufsize 8M \
    -pix_fmt yuv420p \
    -f mpegts udp://127.0.0.1:12395 \
    -loglevel info &

FFMPEG_PID=$!

# Wait for FFmpeg and webhook to initialize
echo ""
echo "Waiting for webhook server to start..."
sleep 3

# Check if webhook is responding
if curl -s -m 2 http://localhost:$WEBHOOK_PORT/ > /dev/null 2>&1; then
    echo "✅ Webhook server is running on port $WEBHOOK_PORT"
else
    echo "⚠️  Webhook server might not be ready yet, waiting..."
    sleep 2
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       🔴 LIVE - Webhook HTTP API Active                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Webhook API: http://localhost:$WEBHOOK_PORT/switch"
echo ""
echo "  Open a NEW TERMINAL and try these commands:"
echo ""
echo "  # Switch to Movie"
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"source\":\"s1\"}'"
echo ""
echo "  # Switch to Blue"
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"source\":\"s2\"}'"
echo ""
echo "  # Switch to Green"
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"source\":\"s3\"}'"
echo ""
echo "  # Switch back to Red"
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"source\":\"s0\"}'"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Or try automatic switching demo:"
echo ""

# Automatic demo
sleep 2
echo "▶️  Automatic demo starting in 3 seconds..."
sleep 3

echo ""
echo "Switching to Movie (s1)..."
curl -X POST "http://localhost:$WEBHOOK_PORT/switch" \
     -H "Content-Type: application/json" \
     -d '{"source":"s1"}' 2>/dev/null
echo ""
sleep 5

echo "Switching to Blue (s2)..."
curl -X POST "http://localhost:$WEBHOOK_PORT/switch" \
     -H "Content-Type: application/json" \
     -d '{"source":"s2"}' 2>/dev/null
echo ""
sleep 5

echo "Switching to Green (s3)..."
curl -X POST "http://localhost:$WEBHOOK_PORT/switch" \
     -H "Content-Type: application/json" \
     -d '{"source":"s3"}' 2>/dev/null
echo ""
sleep 5

echo "Switching to Movie (s1)..."
curl -X POST "http://localhost:$WEBHOOK_PORT/switch" \
     -H "Content-Type: application/json" \
     -d '{"source":"s1"}' 2>/dev/null
echo ""
sleep 5

echo "Switching back to Red (s0)..."
curl -X POST "http://localhost:$WEBHOOK_PORT/switch" \
     -H "Content-Type: application/json" \
     -d '{"source":"s0"}' 2>/dev/null
echo ""

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Automatic demo complete!"
echo "  You can continue sending curl commands manually."
echo "  Press Ctrl+C to stop the stream."
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Keep running
wait $FFMPEG_PID

# Cleanup
kill $FFPLAY_PID 2>/dev/null
pkill -9 ffmpeg ffplay 2>/dev/null

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Session Complete                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  The webhook HTTP API allows remote control of MSwitch"
echo "  from any tool that can make HTTP requests."
echo ""
echo "  This is useful for:"
echo "    • Remote control from web interfaces"
echo "    • Integration with automation systems"
echo "    • Control from scripting languages"
echo "    • REST API for production systems"
echo ""

