# SRT Relay Server for MSwitch Direct

## Overview

A lightweight SRT relay server designed specifically for use with FFmpeg's mswitchdirect demuxer. This relay solves the fundamental limitation of FFmpeg's built-in SRT listener, which only supports single-client connections.

## The Problem

FFmpeg's SRT listener (`mode=listener`) is designed for point-to-point streaming:
- Accepts ONE client connection
- Exits when that client disconnects
- Cannot handle multiple simultaneous clients
- Not suitable for relay/proxy scenarios

This makes it incompatible with mswitchdirect, which needs persistent connections to multiple sources.

## The Solution

This SRT relay server:
- ✅ Accepts source streams on one port
- ✅ Provides multiple output ports for clients
- ✅ Handles client disconnects gracefully
- ✅ Stays running even when sources/clients reconnect
- ✅ Broadcasts to all connected clients simultaneously
- ✅ Perfect for mswitchdirect multi-source failover

## Architecture

```
┌─────────────┐         ┌─────────────┐         ┌──────────────┐
│  Source 0   │────────▶│             │────────▶│  Port 12350  │──┐
└─────────────┘         │             │         └──────────────┘  │
                        │  SRT Relay  │                           │
┌─────────────┐         │   Port 9000 │         ┌──────────────┐  │
│  Source 1   │────────▶│             │────────▶│  Port 12351  │──┼──▶ MSwitch
└─────────────┘         │             │         └──────────────┘  │
                        │             │                           │
┌─────────────┐         │             │         ┌──────────────┐  │
│  Source 2   │────────▶│             │────────▶│  Port 12352  │──┘
└─────────────┘         └─────────────┘         └──────────────┘
```

## Building

```bash
cd .archive
make -f Makefile.srt_relay
```

This creates the `srt_relay` binary.

## Usage

### Basic Usage

```bash
./srt_relay <input_port> <output_port_1> [output_port_2] [output_port_3] ...
```

### Example

```bash
# Start relay: input on 9000, outputs on 12350, 12351, 12352
./srt_relay 9000 12350 12351 12352
```

### With FFmpeg Sources

```bash
# Terminal 1: Start relay
./srt_relay 9000 12350 12351 12352

# Terminal 2: Source 0
ffmpeg -re -i input0.mp4 \
  -c:v libx264 -preset ultrafast \
  -f mpegts "srt://127.0.0.1:9000?streamid=source0"

# Terminal 3: Source 1
ffmpeg -re -i input1.mp4 \
  -c:v libx264 -preset ultrafast \
  -f mpegts "srt://127.0.0.1:9000?streamid=source1"

# Terminal 4: Source 2
ffmpeg -re -i input2.mp4 \
  -c:v libx264 -preset ultrafast \
  -f mpegts "srt://127.0.0.1:9000?streamid=source2"

# Terminal 5: MSwitch Direct
ffmpeg -f mswitchdirect \
  -msw_sources "srt://127.0.0.1:12350?mode=caller,srt://127.0.0.1:12351?mode=caller,srt://127.0.0.1:12352?mode=caller" \
  -msw_port 8099 -msw_auto_failover 1 \
  -i dummy -c:v copy \
  -f mpegts udp://output:5000
```

## Quick Test

Run the automated test script:

```bash
./.archive/test_srt_with_relay.sh
```

This will:
1. Start the SRT relay
2. Start 3 test video sources
3. Start mswitchdirect
4. Output to UDP for viewing

Then in another terminal:
```bash
ffplay udp://127.0.0.1:12360
curl -X POST http://localhost:8099/switch/1  # Switch sources
```

## Features

### Multi-Client Support
- Up to 10 simultaneous clients per output port
- Clients can connect/disconnect freely
- Relay continues running

### Robust Connection Handling
- Graceful handling of source disconnects
- Automatic client cleanup on disconnect
- No crashes or deadlocks

### Low Latency
- Direct packet relay (no transcoding)
- Minimal buffering
- Suitable for live streaming

### Thread-Safe
- Separate threads for input and each output port
- Mutex-protected client list
- Safe concurrent access

## Limitations

### Current Implementation
- **Single source per relay instance**: Each relay accepts one source stream
- **No authentication**: Anyone can connect
- **No encryption beyond SRT**: Uses SRT's built-in encryption only
- **Fixed buffer size**: 2KB packets (suitable for most video streams)

### For Multiple Sources (Required for MSwitch)

**Important:** Each source needs its own relay instance. The relay accepts ONE input source and can broadcast to multiple clients.

For mswitchdirect with 3 sources, run 3 relay instances:

```bash
# Relay 0: input 9000 → output 12350
./srt_relay 9000 12350 &

# Relay 1: input 9001 → output 12351
./srt_relay 9001 12351 &

# Relay 2: input 9002 → output 12352
./srt_relay 9002 12352 &

# Then sources publish to different input ports:
ffmpeg -i input0.mp4 -f mpegts "srt://127.0.0.1:9000" &
ffmpeg -i input1.mp4 -f mpegts "srt://127.0.0.1:9001" &
ffmpeg -i input2.mp4 -f mpegts "srt://127.0.0.1:9002" &

# And mswitchdirect connects to the output ports:
ffmpeg -f mswitchdirect \
  -msw_sources "srt://127.0.0.1:12350?mode=caller,srt://127.0.0.1:12351?mode=caller,srt://127.0.0.1:12352?mode=caller" \
  ...
```

## Comparison: UDP vs SRT Relay

| Feature | UDP | SRT + Relay | FFmpeg SRT Listener |
|---------|-----|-------------|---------------------|
| **Multi-client** | ✅ Yes | ✅ Yes | ❌ No |
| **Reliability** | ❌ No (packet loss) | ✅ Yes (retransmission) | ✅ Yes |
| **Encryption** | ❌ No | ✅ Yes | ✅ Yes |
| **LAN/Local** | ✅ Perfect | ⚠️ Overkill | ❌ Incompatible |
| **Internet/WAN** | ❌ Unreliable | ✅ Perfect | ❌ Incompatible |
| **Latency** | ✅ Lowest | ✅ Low | ✅ Low |
| **Setup complexity** | ✅ Simple | ⚠️ Moderate | ✅ Simple |

## Recommendations

### Use UDP when:
- Streaming on LAN/local network
- Minimal packet loss expected
- Lowest possible latency required
- Simple setup preferred

### Use SRT Relay when:
- Streaming over internet/WAN
- Packet loss is expected
- Encryption is required
- Need reliable delivery with retransmission

### Don't use FFmpeg SRT listener for:
- Multi-source scenarios (like mswitchdirect)
- Relay/proxy applications
- Production streaming servers

## Troubleshooting

### "Address already in use"
Another process is using the port. Change ports or kill the other process:
```bash
lsof -i :9000
kill <PID>
```

### "Connection refused"
Make sure the relay is running before starting sources/clients.

### High CPU usage
The relay is single-threaded per stream. For many streams, consider:
- Running multiple relay instances
- Using a production SRT server (srt-live-server, Haivision)

### Clients not receiving data
Check that:
1. Source is connected (check relay output)
2. Clients are using `mode=caller`
3. Firewall allows connections
4. Ports are correct

## Production Alternatives

For production deployments, consider:

### srt-live-server
- Full-featured SRT relay
- Web UI for monitoring
- Better performance
- More configuration options

```bash
brew install srt-live-server
srt-live-server srt-live-server.conf
```

### Haivision SRT Gateway
- Commercial solution
- Enterprise features
- Professional support
- Clustering and redundancy

### This Relay vs Production Servers

This relay is perfect for:
- ✅ Development and testing
- ✅ Small deployments (< 10 clients)
- ✅ Learning SRT concepts
- ✅ Quick prototyping

Use production servers for:
- Large scale (100+ clients)
- Mission-critical applications
- Advanced features (recording, transcoding)
- Professional support requirements

## License

This SRT relay is provided as-is for use with FFmpeg and mswitchdirect.
Uses the SRT library (Mozilla Public License 2.0).

## Credits

- Built for FFmpeg's mswitchdirect demuxer
- Uses Haivision's SRT library
- Inspired by srt-live-server
