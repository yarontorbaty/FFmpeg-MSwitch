#!/bin/bash

# Verify that each subprocess is generating different colored outputs
# Test each source independently by capturing frames

FFMPEG_PATH="${FFMPEG_PATH:-./ffmpeg}"

echo "============================================================"
echo "  Testing Individual Source Outputs"
echo "============================================================"
echo ""

rm -f /tmp/test_red.jpg /tmp/test_green.jpg /tmp/test_blue.jpg

echo "Step 1: Test RED source directly"
echo "------------------------------------------------------------"
"$FFMPEG_PATH" -f lavfi -i "color=red:size=640x480:rate=25" \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 10 -keyint_min 10 -sc_threshold 0 -pix_fmt yuv420p \
    -vframes 1 -f image2 /tmp/test_red.jpg \
    > /tmp/test_red.log 2>&1

if [ -f /tmp/test_red.jpg ]; then
    SIZE=$(wc -c < /tmp/test_red.jpg)
    echo "✅ RED source generated frame: $SIZE bytes"
else
    echo "❌ RED source failed"
    cat /tmp/test_red.log
fi
echo ""

echo "Step 2: Test GREEN source directly"
echo "------------------------------------------------------------"
"$FFMPEG_PATH" -f lavfi -i "color=green:size=640x480:rate=25" \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 10 -keyint_min 10 -sc_threshold 0 -pix_fmt yuv420p \
    -vframes 1 -f image2 /tmp/test_green.jpg \
    > /tmp/test_green.log 2>&1

if [ -f /tmp/test_green.jpg ]; then
    SIZE=$(wc -c < /tmp/test_green.jpg)
    echo "✅ GREEN source generated frame: $SIZE bytes"
else
    echo "❌ GREEN source failed"
    cat /tmp/test_green.log
fi
echo ""

echo "Step 3: Test BLUE source directly"
echo "------------------------------------------------------------"
"$FFMPEG_PATH" -f lavfi -i "color=blue:size=640x480:rate=25" \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 10 -keyint_min 10 -sc_threshold 0 -pix_fmt yuv420p \
    -vframes 1 -f image2 /tmp/test_blue.jpg \
    > /tmp/test_blue.log 2>&1

if [ -f /tmp/test_blue.jpg ]; then
    SIZE=$(wc -c < /tmp/test_blue.jpg)
    echo "✅ BLUE source generated frame: $SIZE bytes"
else
    echo "❌ BLUE source failed"
    cat /tmp/test_blue.log
fi
echo ""

echo "Step 4: Compare file sizes"
echo "------------------------------------------------------------"
ls -lh /tmp/test_*.jpg 2>/dev/null
echo ""

echo "Step 5: Check if files are actually different (md5sum)"
echo "------------------------------------------------------------"
if [ -f /tmp/test_red.jpg ] && [ -f /tmp/test_green.jpg ] && [ -f /tmp/test_blue.jpg ]; then
    RED_MD5=$(md5 -q /tmp/test_red.jpg)
    GREEN_MD5=$(md5 -q /tmp/test_green.jpg)
    BLUE_MD5=$(md5 -q /tmp/test_blue.jpg)
    
    echo "RED:   $RED_MD5"
    echo "GREEN: $GREEN_MD5"
    echo "BLUE:  $BLUE_MD5"
    echo ""
    
    if [ "$RED_MD5" = "$GREEN_MD5" ] || [ "$RED_MD5" = "$BLUE_MD5" ] || [ "$GREEN_MD5" = "$BLUE_MD5" ]; then
        echo "❌ PROBLEM: Some files are identical!"
        echo "   The sources may not be generating different colors."
    else
        echo "✅ SUCCESS: All three files are different"
        echo "   Sources are generating distinct outputs."
    fi
else
    echo "❌ Not all test files were created"
fi
echo ""

echo "============================================================"
echo "  Now testing MSwitch subprocess command generation"
echo "============================================================"
echo ""

# Check what command MSwitch actually generates
"$FFMPEG_PATH" -f mswitch \
    -i "sources=color=red:size=640x480:rate=25,color=green:size=640x480:rate=25,color=blue:size=640x480:rate=25&control=8099&mode=seamless" \
    -t 2 -f null - \
    > /tmp/mswitch_startup.log 2>&1 &

MSWITCH_PID=$!
sleep 3

echo "Checking subprocess commands from MSwitch logs:"
grep "Starting subprocess" /tmp/mswitch_startup.log
echo ""

echo "Checking actual running processes:"
ps aux | grep -E "color=(red|green|blue)" | grep -v grep | head -3
echo ""

kill $MSWITCH_PID 2>/dev/null
pkill -9 ffmpeg 2>/dev/null

echo "============================================================"
echo "Summary"
echo "============================================================"
echo "Files created: /tmp/test_red.jpg, /tmp/test_green.jpg, /tmp/test_blue.jpg"
echo "You can open these in an image viewer to visually confirm colors."
echo ""

