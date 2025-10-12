# VLC Test with Strict CBR - Copy/Paste Commands

## Setup (3 Terminals)

### Terminal 1: Docker Receiver with Network Simulation

```bash
# Clean up first
docker stop srt-test 2>/dev/null
docker rm srt-test 2>/dev/null

# Run receiver with network simulation
docker run -it --name srt-test --cap-add=NET_ADMIN \
    -p 4200:4200/udp \
    srt-navrc-test \
    bash -c '
    ffmpeg -hide_banner -v info \
        -protocol_whitelist file,udp,srt \
        -i "srt://0.0.0.0:4200?mode=listener&latency=200&enable_stats=1" \
        -c copy -f null - 2>&1 | grep --line-buffered "SRT Stats" &
    
    sleep 8
    tc qdisc add dev eth0 root handle 1: htb default 10
    
    echo "════════════════════════════════════════"
    echo "Phase 1: 10 Mbps (30 seconds)"
    echo "════════════════════════════════════════"
    tc class add dev eth0 parent 1: classid 1:10 htb rate 10mbit
    sleep 30
    
    echo ""
    echo "════════════════════════════════════════"
    echo "Phase 2: 2 Mbps - WATCH VLC!"
    echo "════════════════════════════════════════"
    tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 2mbit
    sleep 30
    
    echo ""
    echo "════════════════════════════════════════"
    echo "Phase 3: 8 Mbps - Recovery"
    echo "════════════════════════════════════════"
    tc qdisc change dev eth0 parent 1: classid 1:10 htb rate 8mbit
    sleep 30
    
    echo ""
    echo "✅ Complete!"
    wait
    '
```

### Terminal 2: Open VLC

```bash
/Applications/VLC.app/Contents/MacOS/VLC udp://@:5000
```

**Or use GUI:**
1. Open VLC
2. File → Open Network Stream (Cmd+N)
3. Enter: `udp://@:5000`
4. Click Play

**Then:** Tools → Media Information → Statistics (Cmd+I)

### Terminal 3: FFmpeg Encoder (STRICT CBR - 5 Mbps)

```bash
cd /Users/yarontorbaty/Documents/Code/FFmpeg

./ffmpeg -re \
    -f lavfi -i "smptebars=size=1280x720:rate=25:duration=90" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=90" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -x264-params "nal-hrd=cbr:force-cfr=1:bitrate=5000:vbv-maxrate=5000:vbv-bufsize=5000:keyint=50:bframes=0" \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:4200?latency=200&enable_stats=1" \
    -f mpegts "udp://localhost:5000?pkt_size=1316"
```

---

## What You'll See

### In VLC:
- **SMPTE color bars** (standard test pattern)
- **Smooth playback** initially
- **Phase 2 (at 30s)**: Network drops to 2 Mbps
  - Watch for buffering/stuttering
  - Check Statistics: packet loss may appear
- **Phase 3 (at 60s)**: Recovery

### In VLC Statistics (Tools → Media Information → Statistics):
- **Input bitrate**: Should show ~5000 kbits/s initially
- **Phase 1**: Stable ~5 Mbps
- **Phase 2**: Watch for packet loss counter increasing
- **Phase 3**: Should stabilize again

### In Terminal 1 (Docker):
- You'll see "SRT Stats" messages
- Network phase announcements

### In Terminal 3 (FFmpeg):
- Encoding stats showing ~5000 kbits/s
- Frame counters

---

## Why Strict CBR?

**Without CBR**: Simple test patterns compress to ~1 Mbps (too efficient!)  
**With CBR**: Forces exactly 5 Mbps output regardless of complexity

### CBR Parameters Explained:
- `nal-hrd=cbr` - Strict constant bitrate mode
- `force-cfr=1` - Constant frame rate
- `bitrate=5000` - Target 5000 kbps (5 Mbps)
- `vbv-maxrate=5000` - VBV max rate = bitrate (strict)
- `vbv-bufsize=5000` - VBV buffer = bitrate (1 second)
- `keyint=50` - Keyframe every 50 frames (2 seconds)
- `bframes=0` - No B-frames for low latency

---

## Expected Results

| Phase | Network | Encoder Output | What Happens |
|-------|---------|----------------|--------------|
| 1 (0-30s) | 10 Mbps | 5 Mbps | ✅ Smooth, no issues |
| 2 (30-60s) | 2 Mbps | 5 Mbps | ⚠️ Packet loss/buffering |
| 3 (60-90s) | 8 Mbps | 5 Mbps | ✅ Recovery, smooth |

**This demonstrates** that when encoder outputs 5 Mbps constant but network only allows 2 Mbps, you get packet loss - showing why adaptive rate control is needed!

---

## Start the Test

1. **Terminal 1**: Run Docker command (wait for "Phase 1" message)
2. **Terminal 2**: Open VLC, open Statistics window
3. **Terminal 3**: Start FFmpeg encoder
4. **Watch VLC Statistics** as phases change!

---

## For Text Overlay (if desired)

Add this to the FFmpeg command after `smptebars`:

```bash
-vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='Phase %{eif\:floor(t/30)+1\:d} - Target 5Mbps CBR':fontsize=48:fontcolor=white:box=1:boxcolor=black@0.8:x=(w-text_w)/2:y=50"
```

Full command with overlay:

```bash
./ffmpeg -re \
    -f lavfi -i "smptebars=size=1280x720:rate=25:duration=90" \
    -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=90" \
    -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='CBR 5Mbps - Phase %{eif\:floor(t/30)+1\:d}/3':fontsize=48:fontcolor=white:box=1:boxcolor=black@0.8:x=(w-text_w)/2:y=50" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -x264-params "nal-hrd=cbr:force-cfr=1:bitrate=5000:vbv-maxrate=5000:vbv-bufsize=5000:keyint=50:bframes=0" \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:4200?latency=200&enable_stats=1" \
    -f mpegts "udp://localhost:5000?pkt_size=1316"
```

---

**Ready to run!** Start with Terminal 1, then 2, then 3.

