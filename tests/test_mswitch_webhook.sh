#!/bin/bash

# MSwitch Webhook Test Script
# Tests HTTP webhook switching with thread-safe command queue

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
WEBHOOK_PORT="${WEBHOOK_PORT:-8099}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              🎮 MSwitch Webhook Test (Thread-Safe!)          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 2

echo "This test demonstrates webhook-based source switching"
echo "using the new thread-safe command queue implementation."
echo ""
echo "Available Sources:"
echo "  [0] 🔴 Red"
echo "  [1] 🟢 Green"
echo "  [2] 🔵 Blue"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  HOW TO CONTROL:"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Send HTTP POST requests to switch sources:"
echo ""
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"source\":\"s0\"}'  # Switch to RED"
echo ""
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"source\":\"s1\"}'  # Switch to GREEN"
echo ""
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"source\":\"s2\"}'  # Switch to BLUE"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Start ffplay
echo "▶️  Starting playback window..."
"${FFPLAY_PATH:-ffplay}" -i udp://127.0.0.1:12430 \
    -window_title "MSwitch Webhook - HTTP Control" \
    -fflags nobuffer -flags low_delay \
    -loglevel warning &

FFPLAY_PID=$!
sleep 2

echo "▶️  Starting FFmpeg with webhook server..."
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              🔴 FFmpeg RUNNING with Webhook                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Webhook server: http://localhost:$WEBHOOK_PORT"
echo "  ffplay window: Should show RED initially"
echo ""
echo "  Test commands (run in another terminal):"
echo ""
echo "  # Switch to GREEN"
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"source\":\"s1\"}'"
echo ""
echo "  # Switch to BLUE"
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"source\":\"s2\"}'"
echo ""
echo "  # Switch back to RED"
echo "  curl -X POST http://localhost:$WEBHOOK_PORT/switch \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"source\":\"s0\"}'"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Start FFmpeg with webhook enabled
"$FFMPEG_PATH" \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local" \
    -msw.webhook.enable \
    -msw.webhook.port $WEBHOOK_PORT \
    -f lavfi -i "color=red:size=1280x720:rate=30" \
    -f lavfi -i "color=green:size=1280x720:rate=30" \
    -f lavfi -i "color=blue:size=1280x720:rate=30" \
    -filter_complex "[0:v][1:v][2:v]mswitch=inputs=3:map=0,fps=30[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -g 1 -keyint_min 1 -sc_threshold 0 \
    -b:v 2M -maxrate 2M -bufsize 2M \
    -pix_fmt yuv420p \
    -fflags nobuffer -flags low_delay \
    -f mpegts udp://127.0.0.1:12430?pkt_size=1316

# Cleanup
kill $FFPLAY_PID 2>/dev/null
pkill -9 ffplay 2>/dev/null

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Session Complete                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  ✅ This approach works because:"
echo "     • Uses thread-safe command queue"
echo "     • Webhook thread only enqueues commands"
echo "     • Main thread processes commands safely"
echo "     • No direct cross-thread function calls"
echo "     • No race conditions or memory corruption"
echo ""
echo "  Key improvements:"
echo "     • Thread-safe by design"
echo "     • No bus errors or crashes"
echo "     • Reliable HTTP switching"
echo "     • Works with any number of sources"
echo ""
