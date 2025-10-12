# Quick Start Guide: Enhanced SRT FFmpeg

## TL;DR

Enhanced FFmpeg with:
1. ✅ Real-time bandwidth monitoring
2. ✅ Adaptive bitrate control for x264/x265
3. ✅ ABR switching with multiple SRT inputs

## Quick Build

```bash
cd /Users/yarontorbaty/Documents/Code/FFmpeg
./build_with_enhanced_srt.sh
```

## Quick Test

### Test 1: Bandwidth Monitoring (30 seconds)

```bash
# Terminal 1
./ffmpeg -i "srt://localhost:4200?mode=listener&enable_stats=1" -f null -

# Terminal 2  
./ffmpeg -re -f lavfi -i testsrc=size=1280x720:rate=25 \
  -c:v libx264 -b:v 5M -f mpegts "srt://localhost:4200?enable_stats=1"

# Look for: [libsrt @ 0x...] SRT Stats: BW=... Mbps, Loss=...%, RTT=... ms
```

### Test 2: Rate Control Demo (compile & run)

```bash
cd examples

gcc srt_rate_control_demo.c \
  -I.. -I../libavcodec -I../libavformat -I../libavutil \
  -L.. -lavcodec -lavformat -lavutil -lswresample \
  -o srt_rate_control_demo

./srt_rate_control_demo ../test.mp4 "srt://localhost:4200?enable_stats=1"
```

### Test 3: ABR Switching (3 sources)

```bash
cd examples

gcc srt_abr_demo.c \
  -I.. -I../libavformat -I../libavutil \
  -L.. -lavformat -lavutil \
  -o srt_abr_demo

# Terminal 1-3: Start 3 sources
for port in 4200 4201 4202; do
  ./ffmpeg -re -f lavfi -i testsrc -c:v libx264 -b:v ${port}k \
    -f mpegts "srt://localhost:${port}?mode=listener" &
done

# Terminal 4: Run ABR
./srt_abr_demo output.ts \
  "srt://localhost:4200" "srt://localhost:4201" "srt://localhost:4202"
```

## What You Get

### Feature 1: Bandwidth Monitoring
- Real-time network statistics
- Quality assessment (Excellent/Good/Fair/Poor/Critical)
- Just add `?enable_stats=1` to SRT URL

### Feature 2: Rate Control
- Automatic encoder bitrate adjustment
- Based on packet loss, RTT, bandwidth
- Emergency mode on severe packet loss
- Min/max bitrate configuration

### Feature 3: ABR Switching
- Multiple SRT inputs (up to 8)
- Automatic failover on connection issues
- Quality-based switching when stable
- Seamless transitions

## Documentation

- **Full Guide**: `SRT_INTEGRATION_README.md`
- **Technical Details**: `INTEGRATION_SUMMARY.md`
- **Implementation**: `IMPLEMENTATION_COMPLETE.md`
- **API Docs**: `doc/srt_integration.md`

## Quick Help

**Build fails?**
```bash
# Check enhanced SRT
ls -la /Users/yarontorbaty/Documents/Code/srt/build/libsrt.*
cd /Users/yarontorbaty/Documents/Code/srt/build && make
```

**No stats showing?**
```bash
# Use verbose logging
./ffmpeg -v verbose ...
```

**Rate control not working?**
- Verify `enable_stats=1` in URL
- Check encoder is libx264 (full support) or libx265 (limited)

## Files Structure

```
FFmpeg/
├── libavformat/
│   ├── srt_bandwidth.{h,c}      ← Bandwidth monitoring
│   ├── srt_abr_switch.{h,c}     ← ABR switching
│   └── libsrt.c (modified)      ← Stats exposure
├── libavcodec/
│   ├── srt_rate_control.{h,c}   ← Rate control
│   └── Makefile (modified)      ← Link with encoders
├── examples/
│   ├── srt_rate_control_demo.c  ← Demo app
│   └── srt_abr_demo.c           ← ABR demo
├── doc/
│   └── srt_integration.md       ← Full docs
├── build_with_enhanced_srt.sh   ← Build script
├── SRT_INTEGRATION_README.md    ← This guide
└── IMPLEMENTATION_COMPLETE.md   ← Status report
```

## Next Steps

1. ✅ Build: `./build_with_enhanced_srt.sh`
2. ⏳ Test: Run the 3 quick tests above
3. 📖 Read: Check full documentation
4. 🔧 Tune: Adjust parameters for your network
5. 🚀 Deploy: Use in production

---

**Status**: Ready to build and test!
**Time to test**: ~5 minutes for all three tests
**Time to read docs**: ~15 minutes for full understanding

