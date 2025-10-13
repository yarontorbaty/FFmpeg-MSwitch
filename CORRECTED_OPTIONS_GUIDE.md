# FFmpeg Dynamic Rate Control - Corrected Options Guide

## ✅ Clarified Option Names

The options have been refactored to **clearly separate concerns**:

1. **SRT-specific options**: Only for SRT automatic rate control
2. **Generic rate control options**: Work with BOTH SRT AND HTTP
3. **HTTP-specific options**: Only for HTTP control interface

---

## **Option Categories**

### **1. SRT Rate Control** (Automatic)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `srt_rate_control` | bool | 0 | Enable SRT network-aware rate control |
| `srt_min_bitrate` | int64 | 500000 | Minimum bitrate (bps) |
| `srt_max_bitrate` | int64 | 10000000 | Maximum bitrate (bps) |
| `srt_upshift_delay_ms` | int | 5000 | Delay before upshift (ms) |
| `srt_disable_auto_adjust` | bool | 0 | Disable auto adjustment (HTTP only) |

**Use when**: You want automatic bitrate adaptation based on SRT stats

### **2. Generic Rate Control** (Works with SRT OR HTTP)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable_encoder_restart` | bool | 0 | **Instant bitrate change** (1-2 frame drop) |
| `enable_frame_skip` | bool | 0 | Frame skipping for FPS reduction |
| `enable_dynamic_gop` | bool | 0 | Adjust GOP size based on bitrate |

**Use when**: You want instant bitrate changes (regardless of control method)

### **3. HTTP Control Interface** (Manual)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `http_control_enable` | bool | 0 | Enable HTTP REST API |
| `http_control_port` | int | 8080 | HTTP server port |

**Use when**: You want manual control via REST API

---

## **Usage Examples**

### **Example 1: SRT Auto + Encoder Restart** ✅ RECOMMENDED

```bash
ffmpeg -i input.mp4 \
  -c:v libx264 \
  -b:v 15000k \
  -srt_rate_control 1 \              # Enable SRT automatic
  -srt_min_bitrate 3000000 \
  -srt_max_bitrate 25000000 \
  -srt_upshift_delay_ms 5000 \       # Smart hysteresis
  -enable_encoder_restart 1 \        # INSTANT bitrate changes
  -f mpegts "srt://...?enable_stats=1"
```

**Result**: Automatic SRT control with instant downshift, delayed upshift

### **Example 2: HTTP Control + Encoder Restart**

```bash
ffmpeg -i input.mp4 \
  -c:v libx264 \
  -b:v 20000k \
  -http_control_enable 1 \           # Enable HTTP API
  -http_control_port 8080 \
  -enable_encoder_restart 1 \        # INSTANT changes
  -f mpegts "srt://..."

# Manual control
curl -X POST http://localhost:8080 \
  -d '{"bitrate":8000,"force_idr":1}'
```

**Result**: Manual control with instant bitrate changes

### **Example 3: SRT + HTTP (Combined)**

```bash
ffmpeg -i input.mp4 \
  -c:v libx264 \
  -b:v 15000k \
  -srt_rate_control 1 \              # Automatic SRT
  -srt_min_bitrate 3000000 \
  -srt_max_bitrate 25000000 \
  -srt_upshift_delay_ms 5000 \
  -http_control_enable 1 \           # ALSO enable HTTP
  -http_control_port 8080 \
  -enable_encoder_restart 1 \        # Instant for BOTH
  -f mpegts "srt://...?enable_stats=1"
```

**Result**: Automatic SRT + manual HTTP override capability

### **Example 4: Graceful (No Encoder Restart)**

```bash
ffmpeg -i input.mp4 \
  -c:v libx264 \
  -b:v 10000k \
  -srt_rate_control 1 \
  -srt_min_bitrate 5000000 \
  -srt_max_bitrate 20000000 \
  # enable_encoder_restart NOT set (default=0)
  -f mpegts "srt://...?enable_stats=1"
```

**Result**: Gradual bitrate changes, no frame disruption

---

## **Option Interactions**

### **Encoder Restart (`enable_encoder_restart=1`)**

**Works with**:
- ✅ SRT automatic rate control
- ✅ HTTP manual control
- ✅ Both simultaneously

**Effect**:
- Instant bitrate changes (1-2 frame disruption)
- Fresh encoder state (no historical averaging)
- Clean VBV/HRD state

### **Frame Skipping (`enable_frame_skip=1`)**

**Works with**:
- ✅ SRT automatic rate control
- ✅ HTTP manual control (if FPS command sent)
- ❌ libx265 (not implemented yet)

**Effect**:
- Reduced effective FPS
- Instant bitrate reduction
- Choppy playback during skip

### **Smart Hysteresis (`srt_upshift_delay_ms`)**

**Works with**:
- ✅ SRT automatic rate control ONLY
- ❌ Not applicable to HTTP (instant response)

**Effect**:
- Prevents oscillation
- Delayed upshift, instant downshift
- More stable quality

---

## **Migration from Old Names**

### **DEPRECATED Names** ❌

| Old Name | New Name | Reason |
|----------|----------|--------|
| `http_enable_encoder_restart` | `enable_encoder_restart` | Not HTTP-specific |
| `srt_enable_encoder_restart` | `enable_encoder_restart` | Consolidated |
| `srt_enable_frame_skip` | `enable_frame_skip` | Works with both |

### **Backward Compatibility**

Old scripts using `http_enable_encoder_restart` will work but should be updated:

```bash
# OLD (still works)
-http_enable_encoder_restart 1

# NEW (correct)
-enable_encoder_restart 1
```

---

## **Decision Tree**

```
Do you need instant bitrate changes?
│
├─ YES → Use `-enable_encoder_restart 1`
│   │
│   ├─ Automatic (SRT)? → Add `-srt_rate_control 1`
│   │
│   └─ Manual (HTTP)? → Add `-http_control_enable 1`
│
└─ NO → Use graceful mode (default, no extra flags)
    │
    └─ Still want SRT auto? → Add `-srt_rate_control 1`
```

---

## **Complete Feature Matrix**

| Feature | SRT Auto | HTTP Manual | Encoder Restart | Frame Skip | Hysteresis |
|---------|----------|-------------|-----------------|------------|------------|
| **Option 1** | ✓ | - | ✓ | - | ✓ | 
| `srt_rate_control=1`<br>`enable_encoder_restart=1`<br>`srt_upshift_delay_ms=5000` |
| **Option 2** | - | ✓ | ✓ | - | - |
| `http_control_enable=1`<br>`enable_encoder_restart=1` |
| **Option 3** | ✓ | ✓ | ✓ | - | ✓ |
| `srt_rate_control=1`<br>`http_control_enable=1`<br>`enable_encoder_restart=1`<br>`srt_upshift_delay_ms=5000` |
| **Option 4** | ✓ | - | - | ✓ | ✓ |
| `srt_rate_control=1`<br>`enable_frame_skip=1`<br>`srt_upshift_delay_ms=5000` |

---

## **Best Practices**

### **For Production Streaming**

```bash
-srt_rate_control 1 \
-enable_encoder_restart 1 \          # Instant response
-srt_upshift_delay_ms 8000 \         # Conservative upshift
-srt_min_bitrate 2000000 \
-srt_max_bitrate 15000000 \
-http_control_enable 1 \             # Optional: manual override
-http_control_port 8080
```

### **For Testing/Development**

```bash
-http_control_enable 1 \
-http_control_port 8080 \
-enable_encoder_restart 1            # Manual control with instant changes
```

### **For Broadcast (Stable)**

```bash
-srt_rate_control 1 \
-srt_upshift_delay_ms 15000 \        # Very conservative
-srt_min_bitrate 5000000 \
-srt_max_bitrate 10000000
# enable_encoder_restart NOT set → graceful changes
```

---

## **Summary**

The options are now clearly organized:

1. **SRT options**: Control automatic SRT behavior
2. **Generic options**: Enable features that work with any control method
3. **HTTP options**: Enable the HTTP control interface

This makes it clear that:
- ✅ Encoder restart works with SRT, HTTP, or both
- ✅ Frame skipping works with SRT, HTTP, or both
- ✅ HTTP control is just ONE way to control the encoder
- ✅ All features are modular and independent

---

**Status**: ✅ Options refactored and clarified  
**Next**: Update test scripts and documentation with correct names

