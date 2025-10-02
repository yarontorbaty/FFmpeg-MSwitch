# Phase 2C: Custom MSwitch Demuxer

**Date**: January 2, 2025  
**Approach**: Create custom demuxer for MSwitch  
**Estimated Time**: 3-4 hours  
**Status**: RECOMMENDED ✅

---

## 🎯 Why a Custom Demuxer is BRILLIANT

### The Problem It Solves

**Init Order Issue**:
```
Current: Parse options → Open inputs (-i) → mswitch_init()
Problem: Can't use -i udp://proxy because proxy doesn't exist yet
```

**Custom Demuxer Solution**:
```
With custom demuxer: Parse options → Open inputs (-i mswitch://...) → Demuxer handles everything!
Solution: Demuxer starts proxy, manages subprocesses, forwards packets
```

### Why This Works

1. **✅ FFmpeg's Native Flow**: Demuxers are opened during input initialization
2. **✅ No Init Order Hack**: Works within FFmpeg's existing architecture
3. **✅ Single Binary**: Everything contained in FFmpeg
4. **✅ Clean API**: Use standard `-i mswitch://sources` syntax
5. **✅ Reusable**: Can be used like any other demuxer

---

## 🏗️ Architecture

### Custom Demuxer: `libavformat/mswitchdemux.c`

```
User Command:
./ffmpeg -i mswitch://s0=udp://...,s1=udp://...,s2=udp://... \
         -c:v libx264 -f mpegts - | ffplay -i -

FFmpeg Flow:
1. Parse -i mswitch://...
2. Call mswitch_demuxer_init()
   └─> Start subprocesses
   └─> Start UDP proxy
   └─> Start control server
3. Call mswitch_demuxer_read_packet()
   └─> Return packets from active source
4. Call mswitch_demuxer_close()
   └─> Stop everything
```

### URL Format

```
mswitch://[options]?sources=s0,s1,s2&mode=seamless&control=8099

Examples:
# Simple (lavfi sources)
-i "mswitch://?sources=color=red,color=green,color=blue"

# Full (UDP sources)
-i "mswitch://?sources=udp://127.0.0.1:5000,udp://127.0.0.1:5001,udp://127.0.0.1:5002&mode=seamless&control=8099"

# With subprocess management
-i "mswitch://?subprocess=1&sources=udp://source1,udp://source2,udp://source3"
```

---

## 📋 Implementation Plan

### Step 1: Create Demuxer Skeleton (1 hour)

**New File**: `libavformat/mswitchdemux.c`

```c
#include "avformat.h"
#include "url.h"

typedef struct MSwitchDemuxerContext {
    // Configuration
    int num_sources;
    char *source_urls[MAX_SOURCES];
    int active_source;
    int mode;  // seamless, graceful, cutover
    
    // Subprocess management
    pid_t subprocess_pids[MAX_SOURCES];
    int subprocess_running[MAX_SOURCES];
    
    // UDP proxy
    int source_sockets[MAX_SOURCES];
    int output_socket;
    pthread_t proxy_thread;
    pthread_mutex_t mutex;
    int running;
    
    // Control server
    int control_port;
    pthread_t control_thread;
    
    // Input context for reading proxied stream
    AVFormatContext *input_ctx;
} MSwitchDemuxerContext;

static int mswitch_probe(const AVProbeData *p) {
    // Check if URL starts with "mswitch://"
    if (av_strstart(p->filename, "mswitch://", NULL))
        return AVPROBE_SCORE_MAX;
    return 0;
}

static int mswitch_read_header(AVFormatContext *s) {
    MSwitchDemuxerContext *ctx = s->priv_data;
    
    // Parse URL parameters
    // Start subprocesses
    // Start UDP proxy
    // Start control server
    // Open internal input (from proxy)
    
    return 0;
}

static int mswitch_read_packet(AVFormatContext *s, AVPacket *pkt) {
    MSwitchDemuxerContext *ctx = s->priv_data;
    
    // Read packet from internal input context
    return av_read_frame(ctx->input_ctx, pkt);
}

static int mswitch_read_close(AVFormatContext *s) {
    MSwitchDemuxerContext *ctx = s->priv_data;
    
    // Stop control server
    // Stop UDP proxy
    // Stop subprocesses
    // Close internal input
    
    return 0;
}

const AVInputFormat ff_mswitch_demuxer = {
    .name           = "mswitch",
    .long_name      = "Multi-Source Switch",
    .priv_data_size = sizeof(MSwitchDemuxerContext),
    .read_probe     = mswitch_probe,
    .read_header    = mswitch_read_header,
    .read_packet    = mswitch_read_packet,
    .read_close     = mswitch_read_close,
    .flags          = AVFMT_NOFILE,
};
```

### Step 2: Integrate UDP Proxy Code (1 hour)

**Reuse Phase 2 code**:
- Copy `mswitch_create_udp_socket()` → demuxer
- Copy `mswitch_udp_proxy_thread()` → demuxer
- Adapt to demuxer context structure

### Step 3: Add Control Server (1 hour)

**HTTP endpoints**:
```c
POST /switch?source=1
GET  /status
GET  /health
```

Reuse webhook code from `fftools/ffmpeg_mswitch.c`

### Step 4: Parse URL Parameters (30 min)

```c
static int parse_mswitch_url(MSwitchDemuxerContext *ctx, const char *url) {
    // Parse: mswitch://?sources=s0,s1,s2&mode=seamless&control=8099
    
    AVDictionary *options = NULL;
    av_dict_parse_string(&options, url, "=", "&", 0);
    
    const char *sources = av_dict_get(options, "sources", NULL, 0);
    // Split sources by comma
    
    const char *mode = av_dict_get(options, "mode", NULL, 0);
    // Parse mode
    
    const char *control = av_dict_get(options, "control", NULL, 0);
    ctx->control_port = control ? atoi(control) : 8099;
    
    av_dict_free(&options);
    return 0;
}
```

### Step 5: Register Demuxer (30 min)

**File**: `libavformat/allformats.c`
```c
extern const AVInputFormat ff_mswitch_demuxer;

// Add to demuxer list
```

**File**: `libavformat/Makefile`
```makefile
OBJS-$(CONFIG_MSWITCH_DEMUXER) += mswitchdemux.o
```

**File**: `configure`
```bash
# Add mswitch demuxer option
```

---

## 🎯 Usage Examples

### Example 1: Simple Color Sources

```bash
./ffmpeg \
    -i "mswitch://?sources=color=red:size=320x240:rate=10,color=green:size=320x240:rate=10,color=blue:size=320x240:rate=10&control=8099" \
    -c:v libx264 -f mpegts - | ffplay -i -

# Switch sources via HTTP
curl -X POST http://localhost:8099/switch?source=1
```

### Example 2: UDP Sources with Subprocesses

```bash
./ffmpeg \
    -i "mswitch://?subprocess=1&sources=color=red,color=green,color=blue&mode=seamless&control=8099" \
    -c:v libx264 -f mpegts - | ffplay -i -
```

### Example 3: External UDP Sources

```bash
# Start external sources first
ffmpeg -f lavfi -i color=red -c:v libx264 -f mpegts udp://127.0.0.1:5000 &
ffmpeg -f lavfi -i color=green -c:v libx264 -f mpegts udp://127.0.0.1:5001 &
ffmpeg -f lavfi -i color=blue -c:v libx264 -f mpegts udp://127.0.0.1:5002 &

# Use MSwitch demuxer
./ffmpeg \
    -i "mswitch://?sources=udp://127.0.0.1:5000,udp://127.0.0.1:5001,udp://127.0.0.1:5002&control=8099" \
    -c:v libx264 -f mpegts - | ffplay -i -
```

---

## ✅ Advantages Over Standalone Proxy

| Feature | Standalone Proxy | Custom Demuxer |
|---------|------------------|----------------|
| Single binary | ❌ | ✅ |
| No init order issue | ✅ | ✅ |
| FFmpeg-native | ❌ | ✅ |
| Standard `-i` syntax | ❌ | ✅ |
| Reusable | ❌ | ✅ |
| Easier to distribute | ❌ | ✅ |
| Matches FFmpeg patterns | ❌ | ✅ |

---

## 🚧 Potential Challenges

### Challenge 1: Internal Input Context

**Problem**: Demuxer needs to read from UDP proxy internally

**Solution**: Create internal `AVFormatContext` for `udp://127.0.0.1:12400`
```c
avformat_open_input(&ctx->input_ctx, "udp://127.0.0.1:12400", NULL, NULL);
avformat_find_stream_info(ctx->input_ctx, NULL);
```

### Challenge 2: Thread Safety

**Problem**: Multiple threads (proxy, control, demuxer read)

**Solution**: Already solved in Phase 2 with mutexes

### Challenge 3: Subprocess Management

**Problem**: Demuxer shouldn't manage subprocesses directly

**Solution**: Make subprocess management optional via URL parameter

---

## 📊 Implementation Estimate

| Task | Time | Complexity |
|------|------|------------|
| Demuxer skeleton | 1 hour | Low |
| Integrate UDP proxy | 1 hour | Low (copy Phase 2) |
| Add control server | 1 hour | Low (copy webhook) |
| URL parsing | 30 min | Low |
| Register & configure | 30 min | Low |
| Testing & debugging | 1 hour | Medium |
| **Total** | **4-5 hours** | **Medium** |

---

## 🎯 Success Criteria

- ✅ Custom demuxer compiles
- ✅ Can open `mswitch://` URL
- ✅ UDP proxy forwards packets
- ✅ Control server accepts commands
- ✅ **Visual switching works** 🎨
- ✅ Clean shutdown
- ✅ No memory leaks

---

## 🚀 Expected Result

```bash
# Single command, everything integrated!
./ffmpeg -i "mswitch://?sources=color=red,color=green,color=blue&control=8099" \
         -c:v libx264 -f mpegts - | ffplay -i - &

# Switch sources
curl -X POST http://localhost:8099/switch?source=1  # → GREEN
curl -X POST http://localhost:8099/switch?source=2  # → BLUE
curl -X POST http://localhost:8099/switch?source=0  # → RED
```

**THIS IS THE GOAL!** 🎯

---

## 💡 Why This is Better

1. **Native FFmpeg Integration** ✅
   - Works like any other input format
   - Follows FFmpeg conventions
   - No special case code

2. **User-Friendly** ✅
   - Standard `-i` syntax
   - Self-contained
   - Easy to document

3. **Maintainable** ✅
   - Isolated in one file
   - Clear responsibility
   - Easy to test

4. **Upstream-Friendly** ✅
   - Could be submitted to FFmpeg upstream
   - Follows demuxer patterns
   - No core modifications

---

*Phase 2C: Custom Demuxer Approach*  
*Estimated Time: 4-5 hours*  
*Recommended: YES ✅*  
*Advantage: Native FFmpeg integration, single binary*

