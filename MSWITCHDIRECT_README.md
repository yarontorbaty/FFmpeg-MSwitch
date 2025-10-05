# MSwitch Direct - Multi-Source Failover Demuxer

A custom FFmpeg demuxer for seamless multi-source video streaming with automatic failover, health monitoring, and manual source switching.

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

```bash
# Configure with standard options
./configure --enable-gpl --enable-libx264

# Build
make -j8

# The resulting ffmpeg binary will include mswitchdirect support
```

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

## Credits

Developed as an extension to FFmpeg's demuxer framework for professional multi-source video streaming applications.
