# Multi-Source Switch (MSwitch) for FFmpeg

## Overview

The Multi-Source Switch (MSwitch) feature allows FFmpeg to seamlessly switch between multiple input sources with different failover modes. This is particularly useful for live streaming scenarios where you need redundancy and automatic failover capabilities.

## Features

- **Multiple Input Sources**: Support for up to 3 input sources (s0, s1, s2)
- **Three Failover Modes**: Seamless, Graceful, and Cutover switching
- **Two Ingestion Modes**: Standby (on-demand) and Hot (parallel processing)
- **Health Monitoring**: Automatic detection of stream loss, black frames, PID loss, and continuity counter errors
- **Control Interfaces**: Webhook API and interactive CLI
- **Automatic Failover**: Configurable thresholds for automatic switching
- **Revert Policies**: Auto or manual revert when primary source recovers

## Basic Usage

### Enable MSwitch Mode

```bash
ffmpeg -msw.enable 1 \
  -msw.sources "s0=rtmp://primary.example.com/live;s1=rtmp://backup.example.com/live" \
  -msw.ingest hot \
  -msw.mode graceful \
  -i rtmp://primary.example.com/live \
  -i rtmp://backup.example.com/live \
  -map 0:v:0 -map 0:a:0 \
  -c copy \
  -f flv rtmp://output.example.com/live
```

### Command Line Options

#### Core Options
- `-msw.enable 1`: Enable multi-source switch mode
- `-msw.sources "s0=url1;s1=url2;s2=url3"`: Define input sources
- `-msw.ingest standby|hot`: Ingestion mode
- `-msw.mode seamless|graceful|cutover`: Failover mode

#### Buffer and Timing
- `-msw.buffer_ms <int>`: Buffer duration in milliseconds
- `-msw.freeze_on_cut <seconds>`: Freeze duration on cutover
- `-msw.on_cut freeze|black`: Action during cutover

#### Control Interfaces
- `-msw.webhook.enable 1`: Enable webhook control
- `-msw.webhook.port 8099`: Webhook server port
- `-msw.cli.enable 1`: Enable interactive CLI

#### Automatic Failover
- `-msw.auto.enable 1`: Enable automatic failover
- `-msw.auto.on "stream_loss=2000,black_ms=800,cc_errors_per_sec=5,packet_loss_percent=2.0,packet_loss_window_sec=10"`: Set thresholds

#### Revert Policy
- `-msw.revert auto|manual`: Revert policy
- `-msw.revert.health_window_ms 5000`: Health window for revert

## Failover Modes

### Seamless Mode
- Requires bit-exact sources (same encoder, same parameters)
- Packet-level switching with minimal buffering
- No visual artifacts during switch
- Best for redundant encoders

### Graceful Mode
- Waits for next IDR/I-frame boundary
- Buffers approximately one GOP duration
- Smooth transition with minimal artifacts
- Best for different sources with similar content

### Cutover Mode
- Immediate switching
- May cause brief visual artifacts
- Fastest switching method
- Best for emergency failover

## Ingestion Modes

### Standby Mode
- Non-primary sources are not connected until needed
- Only metadata is probed
- Lower resource usage
- Slower switching (connection time)

### Hot Mode
- All sources are opened and processed in parallel
- Only active source is fully encoded
- Higher resource usage
- Faster switching (no connection time)

## Health Monitoring

The system monitors several health indicators:

- **Stream Loss**: No packets received for configured duration
- **Black Frame Detection**: Consecutive black frames exceeding threshold
- **PID Loss**: Missing required PIDs (MPEG-TS only)
- **Continuity Counter Errors**: CC errors per second in transport stream
- **Packet Loss Percentage**: Packet loss percentage over a sliding window

## Webhook API

### Endpoints
- `POST /msw`: Main control endpoint

### Commands
```json
{"action": "switch", "target": "s1"}
{"action": "set_mode", "mode": "graceful"}
{"action": "set_auto", "enable": true}
{"action": "revert", "policy": "auto"}
{"action": "status"}
```

## Interactive CLI

Enable with `-msw.cli.enable 1` and use these commands:

```
:msw status
:msw switch s1
:msw mode graceful
:msw revert auto
:msw freeze 2000
:msw black
:msw auto on
```

## JSON Configuration

Create a configuration file and use `-msw.config config.json`:

```json
{
  "sources": [
    {"id": "s0", "url": "srt://host:9000", "latency_ms": 0, "name": "main"},
    {"id": "s1", "url": "file:loop.mp4", "latency_ms": 120, "name": "backup1", "loop": true}
  ],
  "ingest": "hot",
  "mode": "graceful",
  "buffer_ms": 800,
  "on_cut": "freeze",
  "freeze_on_cut": 2000,
  "webhook": {"enable": true, "port": 8099},
  "cli": {"enable": true},
  "auto": {
    "enable": true,
    "thresholds": {"stream_loss": 2000, "black_ms": 800}
  },
  "revert": {"policy": "auto", "health_window_ms": 5000}
}
```

## Examples

### SRT Primary with File Backup
```bash
ffmpeg -msw.enable 1 \
  -msw.sources "s0=srt://encA:9000?mode=listener;s1=file:loop.mp4" \
  -msw.ingest hot \
  -msw.mode graceful \
  -msw.buffer_ms 800 \
  -msw.webhook.enable 1 \
  -msw.webhook.port 8099 \
  -i srt://encA:9000?mode=listener \
  -i file:loop.mp4 \
  -map 0:v:0 -map 0:a:0 \
  -c:v libx264 -c:a aac \
  -f flv rtmp://live/primary
```

### Automatic Failover with Black Detection
```bash
ffmpeg -msw.enable 1 \
  -msw.sources "s0=srt://main:9000;s1=udp://239.0.0.1:1234;s2=file:loop.mp4" \
  -msw.ingest standby \
  -msw.mode cutover \
  -msw.on_cut freeze \
  -msw.freeze_on_cut 2000 \
  -msw.auto.enable 1 \
  -msw.auto.on "stream_loss=1500,black_ms=700" \
  -i srt://main:9000 \
  -i udp://239.0.0.1:1234 \
  -i file:loop.mp4 \
  -map 0:v:0 -map 0:a:0 \
  -c copy \
  -f mpegts udp://239.0.0.2:2000
```

### Seamless Switch Between Time-Locked Encoders
```bash
ffmpeg -msw.enable 1 \
  -msw.mode seamless \
  -msw.buffer_ms 50 \
  -msw.sources "s0=srt://encA:9000;s1=srt://encB:9000" \
  -msw.ingest hot \
  -i srt://encA:9000 \
  -i srt://encB:9000 \
  -map 0 -c copy \
  -f mpegts udp://239.1.1.1:1234
```

## Troubleshooting

### Common Issues

1. **Sources not switching**: Check that sources have compatible stream layouts
2. **Seamless mode not working**: Ensure sources are bit-exact (same encoder, same parameters)
3. **Webhook not responding**: Check firewall settings and port availability
4. **Automatic failover not triggering**: Verify health thresholds are appropriate

### Debug Information

Enable verbose logging to see MSwitch operations:
```bash
ffmpeg -v info -msw.enable 1 ...
```

### Health Monitoring

Monitor health status via webhook:
```bash
curl -X POST http://localhost:8099/msw \
  -H "Content-Type: application/json" \
  -d '{"action": "status"}'
```

## Implementation Notes

- MSwitch is implemented as a controller that orchestrates multiple input sources
- Health monitoring runs in a separate thread
- Switching is thread-safe with atomic operations
- Webhook server is optional and can be disabled
- CLI interface reads from stdin for interactive control
- All operations are logged with appropriate log levels

## Future Enhancements

- Support for more than 3 sources
- Prometheus metrics endpoint
- State persistence across restarts
- Advanced health detection algorithms
- Integration with external monitoring systems
