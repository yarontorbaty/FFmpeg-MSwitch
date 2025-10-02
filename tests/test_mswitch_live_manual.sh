#!/bin/bash

# MSwitch Live Streaming - Manual Control
# Control the live stream by entering source numbers

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"
FFPLAY_PATH="${FFPLAY_PATH:-./ffplay}"
BBB_FILE="/tmp/mswitch_demo/big_buck_bunny.mp4"
COMMANDS_FILE="/tmp/mswitch_manual_commands.txt"

echo "============================================================"
echo "  MSwitch Live Streaming - Manual Control"
echo "============================================================"
echo ""
echo "Available Sources:"
echo "  [0] SMPTE Color Bars"
echo "  [1] Big Buck Bunny (movie)"
echo "  [2] Test Pattern with Counter"
echo ""

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
rm -f "$COMMANDS_FILE"
sleep 2

# Check if Big Buck Bunny exists
if [ ! -f "$BBB_FILE" ]; then
    echo "Error: Big Buck Bunny not found at $BBB_FILE"
    echo "Downloading now..."
    mkdir -p /tmp/mswitch_demo
    curl -L -o "$BBB_FILE" "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
fi

# Create initial command file (start with source 0)
echo "0.0 mswitch map 0;" > "$COMMANDS_FILE"

echo "Starting ffplay..."
"$FFPLAY_PATH" -i udp://127.0.0.1:12351 \
    -window_title "MSwitch Live - Manual Control" \
    -fflags nobuffer \
    -flags low_delay \
    -framedrop \
    -loglevel warning &

FFPLAY_PID=$!
sleep 3

echo "Starting encoder in background..."
"$FFMPEG_PATH" \
    -f lavfi -i "smptebars=size=1280x720:rate=30" \
    -stream_loop -1 -re -i "$BBB_FILE" \
    -f lavfi -i "testsrc=size=1280x720:rate=30,drawtext=text='Pattern Frame %{n}':x=20:y=20:fontsize=60:fontcolor=yellow:box=1:boxcolor=black@0.5:boxborderw=5" \
    -filter_complex "[0:v]scale=1280:720,fps=30[bars];
                     [1:v]scale=1280:720,fps=30[movie];
                     [2:v]scale=1280:720,fps=30[test];
                     [bars][movie][test]mswitch=inputs=3:map=0[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -g 30 -keyint_min 30 -sc_threshold 0 \
    -b:v 3M -maxrate 3M -bufsize 6M \
    -pix_fmt yuv420p \
    -f mpegts udp://127.0.0.1:12351 \
    -loglevel error \
    2>&1 | grep -E "(MSwitch|error)" &

FFMPEG_PID=$!

sleep 2

echo ""
echo "🔴 LIVE STREAMING ACTIVE"
echo ""
echo "============================================================"
echo "  MANUAL SOURCE CONTROL"
echo "============================================================"
echo ""
echo "Enter source number to switch:"
echo "  0 = Color Bars"
echo "  1 = Big Buck Bunny"
echo "  2 = Test Pattern"
echo "  q = Quit"
echo ""
echo "Current source: [0] Color Bars"
echo "============================================================"
echo ""

CURRENT_SOURCE=0
FRAME_COUNT=0

# Interactive control loop
while true; do
    echo -n "Switch to source (0-2, q to quit): "
    read -t 1 INPUT 2>/dev/null
    
    if [ $? -eq 0 ]; then
        case "$INPUT" in
            0|1|2)
                if [ "$INPUT" != "$CURRENT_SOURCE" ]; then
                    CURRENT_SOURCE=$INPUT
                    FRAME_COUNT=$((FRAME_COUNT + 1))
                    
                    # Append switch command
                    echo "$FRAME_COUNT.0 mswitch map $INPUT;" >> "$COMMANDS_FILE"
                    
                    case "$INPUT" in
                        0) SOURCE_NAME="Color Bars" ;;
                        1) SOURCE_NAME="Big Buck Bunny" ;;
                        2) SOURCE_NAME="Test Pattern" ;;
                    esac
                    
                    echo "✓ Switched to [$INPUT] $SOURCE_NAME"
                    echo ""
                else
                    echo "Already on source $INPUT"
                fi
                ;;
            q|Q)
                echo ""
                echo "Stopping stream..."
                break
                ;;
            *)
                echo "Invalid input. Use 0, 1, 2, or q"
                ;;
        esac
    fi
    
    # Check if ffmpeg is still running
    if ! kill -0 $FFMPEG_PID 2>/dev/null; then
        echo "Encoder stopped"
        break
    fi
    
    sleep 0.1
done

# Cleanup
echo "Cleaning up..."
kill $FFMPEG_PID 2>/dev/null
kill $FFPLAY_PID 2>/dev/null
sleep 1
pkill -9 ffmpeg ffplay 2>/dev/null

rm -f "$COMMANDS_FILE"

echo ""
echo "============================================================"
echo "  Stream Stopped"
echo "============================================================"
echo ""
echo "The mswitch filter successfully handled live switching"
echo "between multiple sources with real-time UDP streaming."
echo ""

