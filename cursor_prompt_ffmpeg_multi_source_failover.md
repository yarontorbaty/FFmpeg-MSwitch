You are Cursor, acting as a senior C engineer contributing a feature to an FFmpeg fork. Implement **multi‑source input failover** with CLI + webhook control, standby/hot ingestion, and three failover styles (seamless, graceful, cutover). Build this as a production‑quality change to the `ffmpeg` CLI tool and minimal new library code in `libavformat`/`libavfilter` as needed. Deliver a working PoC plus tests and docs.

---
# Objectives
1) Allow up to three inputs (S0, S1, S2) that have the **same track counts/layout** to be registered as a **multi‑source group**. Switching among them should keep stream topology identical (same number of video/audio tracks; codec/timebase may differ but must be transcodable to a single output graph).
2) Add a **flag to enable multi‑source mode** and a compact syntax for sources and modes.
3) Support two ingestion modes:
   - **standby**: non‑primary inputs are *not* connected until needed; we probe metadata only.
   - **hot**: all inputs are opened and demuxed/decoded in parallel, but only the active path is fully filtered/encoded; non‑actives are decoded to the first post‑decode buffer and dropped.
4) Implement failover styles:
   - **seamless**: pkt‑level splice only if sources are bit‑exact time‑locked encoders. Minimal default buffer (1–2 packets) with configurable `--msw.buffer_ms` for latency offset. Uses DTS/PTS alignment and continuity counters.
   - **graceful**: buffer ≈ GOP duration (ms). Switch on next IDR/I‑frame boundary using PTS to select the best aligned I frame. If buffer not given, estimate from stream analysis (avg keyint/timebase).
   - **cutover**: immediate cut; allow normal decoder/filters to refill.
5) **Control plane**: switching via
   - **interactive CLI** (stdin) with short commands
   - **webhook** (HTTP) to trigger switch/failback and to toggle auto‑modes.
6) **Automatic failover** with thresholds for: stream loss, PID loss, black frame, CC errors. Configurable via CLI or JSON file.
7) On non‑graceful/non‑seamless transitions, optionally **freeze last frame** for X seconds or **send black** before/while the secondary pipeline warms.
8) **Revert policy**: auto‑revert when main healthy, or stay latched to failover until manually switched.

---
# High‑Level Design
- Introduce a new **MultiSourceSwitch (MSwitch)** controller in `fftools/` that orchestrates:
  - Input registration/validation (track counts, channel layouts).
  - Health monitoring per source.
  - Buffering and alignment logic per failover style.
  - Command plane (stdin/webhook) and state machine.
- Where appropriate, create a small helper **lib** in `libavformat/mswitch.c` (if needed) for reusable pkt alignment/buffering and black/freezeframe frame sources; otherwise keep it in `fftools` to avoid public API.
- Add a light **filter graph shim** `vf_mswitch_pad` (if needed) to handle freeze/black insertion and I‑frame gating; but prefer to use existing filters (e.g., `fifo`, `tbuffer`, `blackdetect` analogues for generation) wired by the controller.
- Use **threads**: one demux/dec thread per input in hot mode; a watchdog for health checks; one command server for webhook; a controller loop applying switches.
- **Metrics**: JSON Lines to stderr (or `-report`) for state changes, health metrics, and switch events.

---
# CLI Additions (new options)
```
# Enable multi‑source mode and define sources
-msw.enable 1 \
-msw.sources "s0=<url_or_path>;s1=<url_or_path>;s2=<url_or_path>" \
# optional per‑source options (repeatable or comma‑sep)
-msw.opt.s0 "name=main,latency_ms=0" \
-msw.opt.s1 "name=backup1,latency_ms=120" \
-msw.opt.s2 "name=backup2" \

# ingestion mode
-msw.ingest standby|hot

# failover style
-msw.mode seamless|graceful|cutover

# buffers
-msw.buffer_ms <int>                  # generic buffer for seamless/graceful alignment
-msw.freeze_on_cut <seconds>          # hold last frame for X seconds on non‑graceful
-msw.on_cut black|freeze              # what to render during warmup if not graceful

# webhook control
-msw.webhook.enable 1
-msw.webhook.port 8099
-msw.webhook.methods switch,health,config   # allowed methods

# interactive CLI control (stdin)
-msw.cli.enable 1

# auto‑failover conditions (thresholds)
-msw.auto.enable 1
-msw.auto.on stream_loss=2000, pid_loss=500, black_ms=800, cc_errors=20
# or provide a JSON config
-msw.config /path/to/mswitch.json

# revert policy
-msw.revert auto|manual
-msw.revert.health_window_ms 5000
```

### Interactive CLI (stdin)
```
:msw status
:msw switch s1           # make s1 active
:msw switch s0
:msw mode graceful
:msw revert auto|manual
:msw freeze 2000
:msw black
:msw auto on|off
```

### Webhook API (HTTP)
- Base: `POST /msw` with JSON. Examples:
```json
{"action":"switch","target":"s1"}
{"action":"set_mode","mode":"graceful"}
{"action":"set_auto","enable":true}
{"action":"revert","policy":"auto"}
{"action":"set_thresholds","black_ms":800,"stream_loss":2000}
{"action":"status"}
```
- Responses: JSON with `state`, `active`, `sources`, recent `health`, last `switch_event`.

---
# JSON Config Schema (mswitch.json)
```json
{
  "sources": [
    {"id": "s0", "url": "srt://host:9000?mode=caller", "latency_ms": 0, "name": "main"},
    {"id": "s1", "url": "file:loop.mp4", "latency_ms": 120, "name": "backup1", "loop": true},
    {"id": "s2", "url": "udp://239.0.0.1:1234?fifo_size=5000000", "name": "backup2"}
  ],
  "ingest": "hot",
  "mode": "graceful",
  "buffer_ms": 800,
  "on_cut": "freeze",
  "freeze_on_cut": 2000,
  "webhook": {"enable": true, "port": 8099, "methods": ["switch","health","config"]},
  "cli": {"enable": true},
  "auto": {
    "enable": true,
    "thresholds": {"stream_loss": 2000, "pid_loss": 500, "black_ms": 800, "cc_errors": 20}
  },
  "revert": {"policy": "auto", "health_window_ms": 5000}
}
```

---
# Health/Failure Detection
Implement a per‑source `HealthProbe` with these signals:
- **stream_loss**: no packets across all streams for `stream_loss` ms (wall clock); or demuxer reports EOF/disconnect.
- **pid_loss** (MPEG‑TS only): required PIDs disappear; inspect PMT/continuity; use `AV_PKT_FLAG_DISCARD` and `AVProgram` PID map.
- **black_frame** (video): compute luma mean/variance; frame considered black if mean < Y_black and variance < var_black for N consecutive frames whose duration cumulates ≥ `black_ms`.
- **cc_errors**: count continuity counter errors from TS demuxer; threshold per window.

HealthProbe lives next to demux threads in hot mode; in standby, run lightweight periodic probe (open/close or OPTIONS/peek as supported by protocol) without full decode.

---
# Switching Semantics
- **Seamless**: require `bit_exact` mode: same encoder family, same SPS/PPS/VPS (for H.264/265), same audio frame size/layout. Validate at open: hash extradata and key sequence parameters; if mismatch, downgrade to graceful with a warning. Use pkt PTS/DTS to align; maintain 1–2 pkt ring per input (configurable by `buffer_ms`). Splice at packet boundary; do not flush decoder/filters.
- **Graceful**: hold ~GOP duration in a tbuffer; select the closest future IDR from target whose PTS ≥ current active PTS; perform drain to I‑frame boundary; reinit decoder if codec extradata differs; apply smooth timestamp discontinuity handling via `settb`/`asetpts` if necessary.
- **Cutover**: switch input immediately; allow filtergraph to refill; if `on_cut=freeze`, push last decoded frame repeatedly for `freeze_on_cut` ms; else inject black frames using `color=c=black:s=WxH:r=R` for the gap.

---
# Integration Points in FFmpeg
- Modify `fftools/ffmpeg_opt.c` to parse `-msw.*` options and config file.
- Add `fftools/ffmpeg_mswitch.{c,h}` implementing controller, health probes, and webhook.
- For webhook, embed a tiny HTTP server (e.g., using libmicrohttpd or a minimal custom select() loop; keep external deps optional behind `--enable-microhttpd`). Provide a no‑HTTP build that disables webhook.
- Use existing filters where possible: `fifo`, `tbuffer`, `freezedetect`‑like logic (but we implement our own black detection in C for precision). Use `color`/`nullsrc` to synthesize black. Optionally create a helper source filter `vsrc_freeze` for freeze‑frame.
- Ensure thread safety with atomic `active_index` and a switch barrier that flushes/rewires the active input queue.

---
# Validation of Topology
On startup, inspect all declared sources (or probe on demand in standby) and ensure **same number of video/audio tracks**. If mismatch, refuse to start with a clear error unless `-msw.force_layout 1` is specified (then map a subset consistently and warn).

---
# Examples
## 1) SRT main, MP4 loop backup, graceful switch via webhook
```
ffmpeg -msw.enable 1 \
  -msw.sources "s0=srt://encA:9000?mode=listener; s1=file:loop.mp4" \
  -msw.ingest hot -msw.mode graceful -msw.buffer_ms 800 \
  -msw.webhook.enable 1 -msw.webhook.port 8099 \
  -i srt://encA:9000?mode=listener -i file:loop.mp4 \
  -map 0:v:0 -map 0:a:0 -c:v libx264 -c:a aac -f flv rtmp://live/primary
# then POST {"action":"switch","target":"s1"}
```

## 2) Standby backups, automatic failover on black or loss, cutover + freeze 2s
```
ffmpeg -msw.enable 1 \
  -msw.sources "s0=srt://main:9000; s1=udp://239.0.0.1:1234; s2=file:loop.mp4" \
  -msw.ingest standby -msw.mode cutover -msw.on_cut freeze -msw.freeze_on_cut 2000 \
  -msw.auto.enable 1 -msw.auto.on stream_loss=1500,black_ms=700 \
  -i srt://main:9000 -i udp://239.0.0.1:1234 -i file:loop.mp4 \
  -map 0:v:0 -map 0:a:0 -c copy -f mpegts udp://239.0.0.2:2000
```

## 3) Seamless switch between time‑locked outputs from the same encoder cluster
```
ffmpeg -msw.enable 1 -msw.mode seamless -msw.buffer_ms 50 \
  -msw.sources "s0=srt://encA:9000; s1=srt://encB:9000" \
  -msw.ingest hot \
  -i srt://encA:9000 -i srt://encB:9000 \
  -map 0 -c copy -f mpegts udp://239.1.1.1:1234
```

---
# Implementation Tasks (step‑by‑step)
1. **Option parsing**: add `-msw.*` to `ffmpeg_opt.c`; load JSON config and merge with CLI.
2. **Controller**: implement `MSwitchContext { sources[], active, ingest_mode, mode, buffers, thresholds, revert_policy, metrics }` and state machine.
3. **Input workers**: for hot mode, spawn demux/decode threads per source using `av_read_frame` loops; expose per‑source ring buffers (packet or frame level per mode). For standby, keep URLs and probe function only.
4. **HealthProbe**: implement signals & moving windows (e.g., 1s tick) for stream loss, black_ms, cc_errors, pid_loss. Emit JSON metrics.
5. **Switch logic**:
   - seamless: pkt align and atomic path swap without flushing decoders.
   - graceful: track next IDR; schedule switch; flush/seek if needed; keep PTS continuity.
   - cutover: immediate; trigger freeze/black rendering.
6. **Freeze/black** generators**: last‑frame cache per stream; output duplicates or synthesize black frames up to `freeze_on_cut` ms.
7. **Webhook server**: minimal HTTP parser; routes for `/msw`. JSON in/out using existing cJSON or tiny JSON shim (vendored if necessary) guarded by `--enable-mjson`.
8. **Revert policy**: when auto, require healthy main for `health_window_ms` before switching back; avoid flapping with hysteresis.
9. **Validation/gating**: refuse seamless if SPS/PPS hashes differ; auto‑downgrade to graceful with warning.
10. **Tests**: integration scripts + FATE‑style where possible; synthetic sources with `lavfi`.
11. **Docs**: man page additions and a `doc/mswitch.md` with examples.

---
# Testing Plan
- **Unit-ish**: timebase math, black detection, SPS/PPS hashing.
- **Integration**:
  - Hot vs standby behavior.
  - Seamless switch between identical H.264 streams (use two `tee`d encoders with identical params and `-x264opts sliced-threads=0` for determinism).
  - Graceful switch between differing GOPs; verify no mid‑GOP artifacts; ensure switch at IDR.
  - Cutover with freeze 1000–3000ms; verify black/freeze duration.
  - Auto failover on: unplug SRT (simulate via firewall), drop PIDs on TS (use `mpegts` mux with PID remap), inject black via `color=black` overlay for N ms.
  - Webhook/CLI commands and race conditions (rapid switches).
  - Revert hysteresis and anti‑flap.

---
# Deliverables
- New/changed files:
  - `fftools/ffmpeg_mswitch.c` / `.h`
  - `fftools/ffmpeg_opt.c` (option parsing)
  - `doc/mswitch.md`
  - Optional: `libavformat/mswitch.c` if you choose to factor helpers
- Build flags: `--enable-mswitch` (and optional `--enable-microhttpd`)
- PoC works on Linux/macOS with common protocols (file, srt, udp, rtmp).

---
# Coding/Quality Guidelines
- Follow FFmpeg style; avoid public API unless necessary.
- Prefer **no external deps**; if used, guard with configure flags.
- Comprehensive logging with `av_log` and optional JSON Lines (`-msw.metrics jsonl`).
- Thread‑safe, lock‑minimized; use atomics for hot path.
- Clear error messages and graceful degradation.

---
# Nice‑to‑Haves (if time permits)
- Expose metrics via **prometheus text** on `/metrics`.
- Persist last state to a small file to restore on restart.
- Support **3+ sources** internally, but cap CLI to 3 as spec’d.
- Add `-msw.force_layout` to coerce mapping when backups have superset streams.

---
# Acceptance Criteria
- Can start FFmpeg with `-msw.enable 1` and two or three inputs.
- Manual and webhook switches work.
- Auto failover triggers per thresholds.
- Modes behave as defined; seamless refused if encoders not bit‑exact.
- Freeze/black behavior works for cutovers.
- Revert policy honored and flap‑free.
- Docs explain usage with examples.

---
# Notes/Assumptions
- “PID loss” implies MPEG‑TS ingestion; otherwise ignore.
- “CC errors” sourced from TS demuxer continuity counters.
- For black detection defaults: Y_mean<16 and variance<10 for ≥`black_ms` (tune as needed).
- For seamless, identical codec extradata and timebases are required; otherwise downgrade.

Please generate the code scaffolding, option parsing, controller skeleton, webhook stub, and example docs/tests first, then iterate to working PoC.

