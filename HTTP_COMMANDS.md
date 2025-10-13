# HTTP Encoder Control Commands - Quick Reference

**Server Running**: `http://localhost:8080`
**FFmpeg PID**: Check with `ps aux | grep ffmpeg`
**Logs**: `/tmp/live_http_test.log`

---

## Test Commands

### 1. Reduce to 2 Mbps (Low Quality)
```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"bitrate":2000}'
```

### 2. Increase to 15 Mbps (High Quality)
```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"bitrate":15000}'
```

### 3. Medium Quality (5 Mbps)
```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"bitrate":5000}'
```

### 4. Force IDR Frame (Instant Quality Change)
```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"bitrate":8000,"force_idr":1}'
```

### 5. Change Framerate to 15 fps
```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"fps":15}'
```

### 6. Restore Framerate to 30 fps
```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"fps":30}'
```

### 7. Custom VBV (Tight Control)
```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"bitrate":3000,"vbv_maxrate":3600,"vbv_bufsize":1500}'
```

### 8. Very Low Bitrate (Test Limits)
```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"bitrate":500}'
```

### 9. Maximum Bitrate
```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"bitrate":20000}'
```

### 10. Combined: Bitrate + FPS + IDR
```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"bitrate":6000,"fps":24,"force_idr":1}'
```

---

## Check Encoder Response

### View Recent Logs
```bash
tail -30 /tmp/live_http_test.log
```

### Watch Logs in Real-Time
```bash
tail -f /tmp/live_http_test.log | grep "HTTP Control"
```

### Check Current Bitrate
```bash
tail -1 /tmp/live_http_test.log | grep "bitrate="
```

---

## Expected Behavior

When you send a command, you should see in the logs:

```
[HTTP Control] ═══ RECEIVED COMMAND ═══
[HTTP Control]   Bitrate: XXXX kbps
[HTTP Control]   FPS: XX
[HTTP Control]   Force IDR: X
[HTTP Control] Applying bitrate config:
[HTTP Control]   i_bitrate = XXXX kbps
[HTTP Control]   i_vbv_max_bitrate = XXXX kbps
[HTTP Control]   i_vbv_buffer_size = XXXX kbps
[HTTP Control] ═══ CALLING x264_encoder_reconfig() ═══
[HTTP Control] ✓ ✓ ✓ RECONFIG SUCCESS ✓ ✓ ✓
[HTTP Control] Encoder accepted new parameters
[HTTP Control] ═══ COMMAND COMPLETE ═══
```

In VLC, you should see:
- **Quality changes** within 0.5-2 seconds
- **Smoother/blockier video** as bitrate changes
- **Instant changes** when using `force_idr:1`

---

## Troubleshooting

### FFmpeg Not Responding
```bash
# Check if running
ps aux | grep ffmpeg

# Restart
pkill -f ffmpeg
cd /Users/yarontorbaty/Documents/Code/FFmpeg
./ffmpeg -loglevel info -re -f lavfi -i "testsrc=duration=600:size=1280x720:rate=30,format=yuv420p" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 10000k \
    -http_control_enable 1 -http_control_port 8080 \
    -f mpegts "srt://127.0.0.1:9999?mode=listener&latency=1000" 2>&1 | tee /tmp/live_http_test.log &
```

### VLC Connection Issues
```bash
# Reconnect VLC
open -a VLC "srt://127.0.0.1:9999?mode=caller"
```

### Port Already in Use
```bash
# Kill existing FFmpeg
pkill -9 -f ffmpeg
sleep 2
# Then restart
```

---

## Tips for Testing

1. **Start with gradual changes**: 10000 → 5000 → 2000 → 10000
2. **Use `force_idr:1` for instant changes**
3. **Watch VLC and logs side-by-side**
4. **Try extreme values**: 500 kbps or 20000 kbps
5. **Combine FPS + bitrate changes**
6. **Monitor response time** (should be <2 seconds)

---

**Stop Everything:**
```bash
pkill -f ffmpeg && pkill -f VLC
```

