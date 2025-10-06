# FFmpeg with MSwitch Direct

> **This is a fork of [FFmpeg](https://ffmpeg.org/) with a custom multi-source failover demuxer.**

## MSwitch Direct - Multi-Source Failover Demuxer

A custom FFmpeg demuxer for seamless multi-source video streaming with automatic failover, health monitoring, and manual source switching.

For the original FFmpeg documentation, see [README_FFMPEG.md](README_FFMPEG.md).

## Features

- **Multi-Source Input**: Connect to multiple video sources (UDP, RTSP, etc.)
- **Automatic Failover**: Instantly switch to healthy sources when active source fails
- **Health Monitoring**: Continuous background monitoring of all sources
- **Manual Switching**: HTTP API for manual source control
- **Freeze-Frame**: Repeat last good frame during brief outages
- **Automatic Reconnection**: Sources automatically reconnect when they come back online
- **Timestamp Continuity**: Seamless timestamp handling across switches
- **Zero-Copy Buffer**: Efficient ring buffer for each source

## Building

### Prerequisites
- Standard FFmpeg build dependencies
- libx264 (for encoding examples)

### Build Instructions

#### Basic Build (H.264 only)
```bash
./configure --enable-gpl --enable-libx264
make -j8
```

#### Full Build (All Codecs + SRT + Filters)
```bash
./configure \
  --enable-gpl \
  --enable-version3 \
  --enable-nonfree \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libaom \
  --enable-libsrt \
  --enable-libfreetype \
  --enable-libfontconfig \
  --enable-libharfbuzz \
  --extra-cflags="-I/opt/homebrew/include" \
  --extra-ldflags="-L/opt/homebrew/lib"

make -j8
```

**Supported Codecs:**
- H.264/AVC (libx264)
- HEVC/H.265 (libx265)
- AV1 (libaom-av1)
- Hardware acceleration (VideoToolbox on macOS)

**Supported Protocols:**
- UDP (recommended for LAN)
- RTSP (IP cameras)
- SRT (with relay server - see `.archive/SRT_RELAY_README.md`)
- RTMP (legacy)

**Video Filters:**
- All standard FFmpeg filters enabled
- `drawtext` - Text overlay with TrueType fonts
- `drawbox` - Draw colored boxes
- `overlay` - Overlay videos/images
- `scale` - Resize and format conversion
- `crop` - Crop video
- And 400+ more filters

## Usage

### Basic Command Structure

```bash
ffmpeg -f mswitchdirect \
  -msw_sources "source1,source2,source3" \
  [options] \
  -i dummy \
  [output options] \
  output
```

### Required Parameters

- `-f mswitchdirect`: Use the mswitchdirect demuxer
- `-msw_sources`: Comma-separated list of source URLs (UDP, RTSP, etc.)
- `-i dummy`: Placeholder input (required by FFmpeg syntax)

### Optional Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-msw_port` | 8080 | HTTP control server port |
| `-msw_auto_failover` | 1 | Enable automatic failover (1=on, 0=off) |
| `-msw_health_interval` | 50 | Health check interval in milliseconds |
| `-msw_source_timeout` | 300 | Source timeout in milliseconds |
| `-msw_grace_period` | 3000 | Startup grace period in milliseconds |
| `-msw_reconnect_timeout` | 0 | Reconnect timeout in milliseconds (0=infinite) |
| `-msw_clean_switch` | 0 | Enable clean switching with decoder flush (1=on, 0=off) |

### Recommended Values

#### For Low-Latency Live Streaming
```bash
-msw_health_interval 50 \
-msw_source_timeout 300 \
-msw_grace_period 1000
```
- Fast failover (~300ms detection)
- Minimal freeze time
- Good for live sports, news

#### For Stable Long-Running Streams
```bash
-msw_health_interval 100 \
-msw_source_timeout 1000 \
-msw_grace_period 5000
```
- More tolerant of brief network issues
- Fewer false positives
- Good for 24/7 monitoring

#### For Unreliable Networks
```bash
-msw_health_interval 200 \
-msw_source_timeout 2000 \
-msw_grace_period 10000 \
-msw_reconnect_timeout 0
```
- Maximum tolerance for network issues
- Infinite reconnection attempts
- Good for remote/wireless sources

## Examples

### Example 1: Basic Three-Source Failover

```bash
./ffmpeg -f mswitchdirect \
  -msw_sources "udp://192.168.1.10:5000,udp://192.168.1.11:5000,udp://192.168.1.12:5000" \
  -msw_port 8080 \
  -msw_auto_failover 1 \
  -i dummy \
  -c:v libx264 -preset ultrafast -tune zerolatency \
  -f mpegts udp://239.0.0.1:5000
```

### Example 2: RTSP Sources with Manual Control

```bash
./ffmpeg -f mswitchdirect \
  -msw_sources "rtsp://camera1/stream,rtsp://camera2/stream,rtsp://camera3/stream" \
  -msw_port 9090 \
  -msw_auto_failover 0 \
  -i dummy \
  -c:v copy \
  -f rtsp rtsp://output/stream
```

### Example 3: Low-Latency with Clean Switching

```bash
./ffmpeg -f mswitchdirect \
  -msw_sources "udp://127.0.0.1:12350,udp://127.0.0.1:12351,udp://127.0.0.1:12352" \
  -msw_port 8099 \
  -msw_auto_failover 1 \
  -msw_clean_switch 1 \
  -msw_health_interval 50 \
  -msw_source_timeout 300 \
  -i dummy \
  -c:v libx264 -r 30 -preset ultrafast -g 60 -keyint_min 1 \
  -f mpegts udp://127.0.0.1:12360?pkt_size=1316
```

### Example 4: Recording with Failover

```bash
./ffmpeg -f mswitchdirect \
  -msw_sources "udp://source1:5000,udp://source2:5000" \
  -msw_port 8080 \
  -i dummy \
  -c:v libx264 -preset medium \
  -c:a aac \
  output.mp4
```

### Example 5: HEVC/H.265 Output

```bash
./ffmpeg -f mswitchdirect \
  -msw_sources "udp://192.168.1.10:5000,udp://192.168.1.11:5000" \
  -msw_port 8080 \
  -msw_auto_failover 1 \
  -i dummy \
  -c:v libx265 -preset fast -x265-params log-level=error \
  -f mpegts udp://239.0.0.1:5000
```

### Example 6: AV1 Encoding

```bash
./ffmpeg -f mswitchdirect \
  -msw_sources "udp://source1:5000,udp://source2:5000" \
  -msw_port 8080 \
  -i dummy \
  -c:v libaom-av1 -cpu-used 6 -row-mt 1 \
  -f mpegts udp://output:5000
```

### Example 7: SRT Input and Output

**Note:** If you experience SRT connection issues, see [SRT Setup](#srt-setup) for relay options.

```bash
# Direct connection (if sources support multiple clients)
./ffmpeg -f mswitchdirect \
  -msw_sources "srt://source1.com:9000?mode=caller,srt://source2.com:9000?mode=caller,srt://source3.com:9000?mode=caller" \
  -msw_port 8080 \
  -msw_auto_failover 1 \
  -i dummy \
  -c:v libx264 -preset ultrafast \
  -f mpegts "srt://output.server.com:9000?mode=caller&latency=1000"

# Or with relay (if experiencing connection issues, see SRT Setup section)
./tools/srt_relay/mswitch_srt srt://source1:9000 srt://source2:9000 srt://source3:9000 -- \
  -msw_port 8080 -msw_auto_failover 1 -i dummy -c:v libx264 -f mpegts "srt://output:9000"
```

## SRT Setup

### Direct SRT Connection (Try This First)

If your SRT sources are already coming from a dedicated SRT server or relay that supports multiple clients, you can connect directly:

```bash
./ffmpeg -f mswitchdirect \
  -msw_sources "srt://source1.com:9000?mode=caller,srt://source2.com:9000?mode=caller,srt://source3.com:9000?mode=caller" \
  -msw_port 8080 -msw_auto_failover 1 \
  -i dummy -c:v libx264 -f mpegts udp://output:5000
```

### When You Need the SRT Relay

**Problem:** FFmpeg's built-in SRT listener only supports single-client connections and exits when the client disconnects. This causes issues with mswitchdirect's health checks and reconnection logic.

**Solution:** If you experience connection issues, disconnections, or "no sockets to check" errors when using SRT sources, use our lightweight SRT relay server as an intermediary.

### Using the SRT Relay

**Option 1: Using the Helper Script (Recommended)**

```bash
# The helper script automatically manages relays
./tools/srt_relay/mswitch_srt \
  srt://source1.com:9000 \
  srt://source2.com:9000 \
  srt://source3.com:9000 \
  -- \
  -msw_port 8080 -msw_auto_failover 1 \
  -i dummy -c:v libx264 -f mpegts udp://output:5000
```

**Option 2: Manual Setup**

```bash
# Terminal 1-3: Start one relay per source
cd tools/srt_relay
./srt_relay 9000 12350 &  # Relay for source 0
./srt_relay 9001 12351 &  # Relay for source 1
./srt_relay 9002 12352 &  # Relay for source 2

# Terminal 4-6: Sources publish to relay inputs
ffmpeg -re -i video0.mp4 -c:v libx264 -f mpegts "srt://127.0.0.1:9000" &
ffmpeg -re -i video1.mp4 -c:v libx264 -f mpegts "srt://127.0.0.1:9001" &
ffmpeg -re -i video2.mp4 -c:v libx264 -f mpegts "srt://127.0.0.1:9002" &

# Terminal 7: MSwitch connects to relay outputs
./ffmpeg -f mswitchdirect \
  -msw_sources "srt://127.0.0.1:12350?mode=caller,srt://127.0.0.1:12351?mode=caller,srt://127.0.0.1:12352?mode=caller" \
  -msw_port 8080 -msw_auto_failover 1 \
  -i dummy -c:v libx264 -f mpegts udp://output:5000
```

### Building the SRT Relay

```bash
cd tools/srt_relay
make
```

### Architecture

```
Source 0 ──9000──▶ Relay 0 ──12350──▶ ┐
Source 1 ──9001──▶ Relay 1 ──12351──▶ ├─▶ MSwitch ──▶ Output
Source 2 ──9002──▶ Relay 2 ──12352──▶ ┘
```

**Key Point:** One relay instance per source. Each relay accepts one source and can broadcast to multiple clients.

### For More Details

- **Full documentation:** `tools/srt_relay/README.md`
- **Quick start guide:** `tools/srt_relay/QUICK_START_SRT.md`
- **Test script:** `tools/srt_relay/test_srt_with_relay.sh`

### Comparison: SRT vs UDP

**Use SRT when:**
- Streaming over WAN/Internet
- Need error correction and retransmission
- Network has packet loss or jitter
- Sources already use SRT

**Use UDP when:**
- Streaming on local/LAN network
- Low latency is critical
- Network is reliable
- Simpler setup preferred (no relay needed)

```bash
# Sources (no relay needed!)
ffmpeg -re -i video0.mp4 -c:v libx264 -f mpegts udp://127.0.0.1:12350 &
ffmpeg -re -i video1.mp4 -c:v libx264 -f mpegts udp://127.0.0.1:12351 &

# MSwitch
./ffmpeg -f mswitchdirect \
  -msw_sources "udp://127.0.0.1:12350,udp://127.0.0.1:12351" \
  -msw_port 8080 -i dummy -c:v copy -f mpegts udp://output:5000
```

Use SRT only when you need encryption or reliable delivery over internet/WAN.

## HTTP Control API

The demuxer provides an HTTP API for manual control and status monitoring.

### Switch Source

```bash
# Switch to source 0
curl -X POST http://localhost:8080/switch/0

# Switch to source 1
curl -X POST http://localhost:8080/switch/1
```

**Response Codes:**
- `200 OK`: Switch successful
- `503 Service Unavailable`: Target source is unhealthy
- `400 Bad Request`: Invalid source index

### Get Status

```bash
curl http://localhost:8080/status
```

**Response:**
```json
{
  "active_source": 0,
  "num_sources": 3,
  "auto_failover": true,
  "sources": [
    {"index": 0, "healthy": true, "packets": 12345},
    {"index": 1, "healthy": true, "packets": 12340},
    {"index": 2, "healthy": false, "packets": 0}
  ]
}
```

## How It Works

### Architecture

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  Source 0   │  │  Source 1   │  │  Source 2   │
│   (UDP)     │  │   (UDP)     │  │   (UDP)     │
└──────┬──────┘  └──────┬──────┘  └──────┬──────┘
       │                │                │
       ▼                ▼                ▼
┌──────────────────────────────────────────────┐
│           Reader Threads (per source)        │
│  - Continuous packet reading                 │
│  - Automatic reconnection                    │
│  - Buffer management                         │
└──────┬───────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────┐
│         Ring Buffers (per source)            │
│  - 1000 packet capacity                      │
│  - I-frame tracking                          │
│  - Thread-safe access                        │
└──────┬───────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────┐
│          Health Monitor Thread               │
│  - Periodic health checks                    │
│  - Auto-failover trigger                     │
│  - Source recovery detection                 │
└──────┬───────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────┐
│         Main Read Thread                     │
│  - Active source selection                   │
│  - Timestamp normalization                   │
│  - Freeze-frame generation                   │
└──────┬───────────────────────────────────────┘
       │
       ▼
   FFmpeg Pipeline
```

### Failover Process

1. **Detection**: Health monitor detects unhealthy source (no packets for timeout period)
2. **Selection**: Find next healthy source
3. **Switch**: Update active source index
4. **Continuity**: Timestamp normalization ensures smooth transition
5. **Recovery**: Failed source continues reconnection attempts in background

### Reconnection Process

1. **Error Detection**: Reader thread detects I/O error or EOF
2. **Close Connection**: Clean up existing connection
3. **Retry Loop**: Attempt reconnection every ~1 second
4. **Success**: Resume packet reading and mark source as healthy
5. **Infinite Retry**: Continues until successful (unless timeout is set)

## Troubleshooting

### Issue: Frequent False Failovers

**Symptoms**: Sources marked unhealthy despite being online

**Solution**: Increase timeout values
```bash
-msw_health_interval 100 \
-msw_source_timeout 1000
```

### Issue: Slow Failover

**Symptoms**: Long freeze during source failure

**Solution**: Decrease timeout values
```bash
-msw_health_interval 50 \
-msw_source_timeout 300
```

### Issue: Source Won't Reconnect

**Symptoms**: Source stays offline after restart

**Check**:
1. Verify source is actually sending packets
2. Check logs for reconnection attempts
3. Ensure firewall allows UDP traffic
4. Try manually switching to another source and back

### Issue: Video Corruption on Switch

**Symptoms**: Artifacts or freezing after switch

**Solution**: Enable clean switching
```bash
-msw_clean_switch 1
```

Note: This adds slight delay but ensures decoder reset.

### Issue: Timestamp Jumps

**Symptoms**: Player shows time jumping backward/forward

**This should not happen** - timestamp normalization handles this automatically. If you see this, please report it as a bug.

## Logging

### Enable Debug Logging

```bash
./ffmpeg -v debug -f mswitchdirect ...
```

### Log Levels

- **ERROR**: Fatal errors, reconnection failures
- **WARNING**: Failovers, health changes, manual switches
- **INFO**: Reconnection attempts, first packets
- **DEBUG**: Detailed packet flow, buffer operations

### Key Log Messages

```
[MSwitch Direct] ⚡ AUTO-FAILOVER: Switched from source 0 to 1
  → Automatic failover occurred

[MSwitch Direct Reader] Source 0: ✅ Reconnected successfully!
  → Source came back online

[MSwitch Direct HTTP] Cannot switch to source 1 - source is UNHEALTHY
  → Manual switch blocked (source offline)

[MSwitch Direct Health] Source 2 (inactive) recovered
  → Backup source is now healthy
```

## Performance Considerations

### CPU Usage
- Each source runs in its own thread
- Minimal CPU overhead (~1-2% per source)
- Health monitoring is lightweight (50-200ms intervals)

### Memory Usage
- ~10MB per source (1000 packet buffer)
- Scales linearly with number of sources
- No memory leaks (continuous operation tested)

### Network Bandwidth
- All sources receive packets continuously
- Bandwidth = (number of sources) × (per-source bitrate)
- Example: 3 sources @ 5 Mbps = 15 Mbps total

### Latency
- Failover latency: ~300-500ms (with recommended settings)
- Normal operation: No added latency
- Clean switch: +100-200ms (decoder flush)

## Limitations

1. **Source Compatibility**: All sources must have same codec and resolution
2. **Timestamp Formats**: Sources should use similar timestamp bases
3. **Network**: UDP sources may experience packet loss (normal for UDP)
4. **Platform**: Tested on Linux and macOS, Windows support untested

## Advanced Configuration

### Custom Buffer Sizes

Edit `mswitchdirect.c` and change:
```c
#define PACKET_BUFFER_SIZE 1000  // Increase for longer buffering
```

### Freeze-Frame Duration

Freeze-frame repeats last good frame with incrementing timestamps:
```c
ctx->freeze_frame_duration = 3000;  // 3000 = 100ms at 90kHz timebase
```

### Health Check Tuning

For very stable networks, you can reduce health check frequency:
```bash
-msw_health_interval 500 \
-msw_source_timeout 5000
```

## Contributing

When submitting issues or pull requests:

1. Include full command line
2. Provide relevant log output (with `-v debug`)
3. Describe expected vs actual behavior
4. Include FFmpeg version: `./ffmpeg -version`

## License

This code is part of FFmpeg and follows the same license (LGPL/GPL depending on configuration).

## Upstream FFmpeg

This fork is based on FFmpeg. To stay up to date with upstream changes:

```bash
# Add upstream remote
git remote add upstream https://git.ffmpeg.org/ffmpeg.git

# Fetch upstream changes
git fetch upstream

# Merge upstream master (resolve conflicts if any)
git merge upstream/master
```

**Upstream Repository**: https://git.ffmpeg.org/ffmpeg.git  
**Official Website**: https://ffmpeg.org/

## Credits

- **FFmpeg Team**: Original FFmpeg codebase and framework
- **MSwitch Direct**: Custom demuxer developed for professional multi-source video streaming applications
