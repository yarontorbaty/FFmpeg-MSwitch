#!/bin/bash

# Test different MSwitch modes

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"

test_mode() {
    local mode="$1"
    local test_dir="/tmp/mswitch_mode_${mode}_$$"
    
    echo ""
    echo "========================================"
    echo "Testing MODE: $mode"
    echo "========================================"
    
    mkdir -p "$test_dir"
    pkill -9 ffmpeg 2>/dev/null
    sleep 1
    
    # Start FFmpeg with specified mode
    "$FFMPEG_PATH" -f mswitch \
        -i "sources=color=red:size=320x240:rate=10,color=green:size=320x240:rate=10,color=blue:size=320x240:rate=10&control=8099&mode=$mode" \
        -vf fps=1 -f image2 "$test_dir/frame_%04d.jpg" \
        > "$test_dir/ffmpeg.log" 2>&1 &
    
    FFMPEG_PID=$!
    echo "FFmpeg started (PID: $FFMPEG_PID)"
    sleep 4
    
    # Test switches
    echo "  Switch to source 1 (GREEN)..."
    curl -s -X POST "http://localhost:8099/switch?source=1" > /dev/null
    sleep 2
    
    echo "  Switch to source 2 (BLUE)..."
    curl -s -X POST "http://localhost:8099/switch?source=2" > /dev/null
    sleep 2
    
    echo "  Switch to source 0 (RED)..."
    curl -s -X POST "http://localhost:8099/switch?source=0" > /dev/null
    sleep 2
    
    # Kill FFmpeg
    kill $FFMPEG_PID 2>/dev/null
    wait $FFMPEG_PID 2>/dev/null
    
    # Analyze
    echo ""
    echo "Results for $mode mode:"
    echo "  Frames captured:"
    for i in 1 3 5 7; do
        frame=$(printf "$test_dir/frame_%04d.jpg" $i)
        if [ -f "$frame" ]; then
            size=$(stat -f%z "$frame" 2>/dev/null || stat -c%s "$frame" 2>/dev/null)
            echo "    Frame $i: $size bytes"
        fi
    done
    
    echo "  Switch events:"
    grep -E "(Pending|Seamless|Cutover|Graceful) switch" "$test_dir/ffmpeg.log" | head -5
    
    echo "  Files in: $test_dir"
}

# Test all modes
test_mode "seamless"
test_mode "graceful"
test_mode "cutover"

echo ""
echo "========================================"
echo "All tests complete!"
echo "========================================"

