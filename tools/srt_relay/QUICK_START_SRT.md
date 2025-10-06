# Quick Start: MSwitch Direct with SRT

## TL;DR

For 3 SRT sources with mswitchdirect, you need **3 relay instances** (one per source).

## Architecture

```
Source 0 ──9000──▶ Relay 0 ──12350──▶ ┐
Source 1 ──9001──▶ Relay 1 ──12351──▶ ├─▶ MSwitch ──▶ Output
Source 2 ──9002──▶ Relay 2 ──12352──▶ ┘
```

## Quick Setup

### 1. Start Relays (one per source)

```bash
cd .archive

# Relay 0
./srt_relay 9000 12350 &

# Relay 1
./srt_relay 9001 12351 &

# Relay 2
./srt_relay 9002 12352 &
```

### 2. Start Sources (publish to relay inputs)

```bash
# Source 0 → port 9000
ffmpeg -re -i video0.mp4 -c:v libx264 -f mpegts "srt://127.0.0.1:9000" &

# Source 1 → port 9001
ffmpeg -re -i video1.mp4 -c:v libx264 -f mpegts "srt://127.0.0.1:9001" &

# Source 2 → port 9002
ffmpeg -re -i video2.mp4 -c:v libx264 -f mpegts "srt://127.0.0.1:9002" &
```

### 3. Start MSwitch (connect to relay outputs)

```bash
ffmpeg -f mswitchdirect \
  -msw_sources "srt://127.0.0.1:12350?mode=caller,srt://127.0.0.1:12351?mode=caller,srt://127.0.0.1:12352?mode=caller" \
  -msw_port 8099 \
  -msw_auto_failover 1 \
  -i dummy \
  -c:v libx264 -preset ultrafast \
  -f mpegts udp://output:5000
```

### 4. Control

```bash
# Switch to source 1
curl -X POST http://localhost:8099/switch/1

# Check status
curl http://localhost:8099/status
```

## Or Use the Test Script

```bash
./.archive/test_srt_with_relay.sh
```

## Common Mistakes

### ❌ Wrong: One relay with multiple outputs
```bash
# This DOESN'T work for multiple sources!
./srt_relay 9000 12350 12351 12352
```
This creates ONE relay that broadcasts ONE source to 3 output ports.

### ✅ Correct: One relay per source
```bash
# This works!
./srt_relay 9000 12350 &  # Relay 0
./srt_relay 9001 12351 &  # Relay 1
./srt_relay 9002 12352 &  # Relay 2
```
Each relay handles one source independently.

## Port Mapping

| Component | Input Port | Output Port | Purpose |
|-----------|------------|-------------|---------|
| Relay 0 | 9000 | 12350 | Source 0 relay |
| Relay 1 | 9001 | 12351 | Source 1 relay |
| Relay 2 | 9002 | 12352 | Source 2 relay |
| MSwitch | - | 8099 | HTTP control API |

## Why Multiple Relays?

Each relay instance:
- Accepts **ONE** source connection
- Can broadcast to **multiple** clients
- Handles reconnections for that source

For mswitchdirect with N sources, you need N relays.

## Alternative: Use UDP

For LAN/local streaming, UDP is simpler:

```bash
# Sources (no relay needed!)
ffmpeg -re -i video0.mp4 -c:v libx264 -f mpegts udp://127.0.0.1:12350 &
ffmpeg -re -i video1.mp4 -c:v libx264 -f mpegts udp://127.0.0.1:12351 &
ffmpeg -re -i video2.mp4 -c:v libx264 -f mpegts udp://127.0.0.1:12352 &

# MSwitch (same as before, just UDP URLs)
ffmpeg -f mswitchdirect \
  -msw_sources "udp://127.0.0.1:12350,udp://127.0.0.1:12351,udp://127.0.0.1:12352" \
  ...
```

Use SRT only when you need encryption or streaming over internet/WAN.
