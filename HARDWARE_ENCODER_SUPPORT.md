# Hardware Encoder Support Status

## Summary

This document explains dynamic bitrate control support across different encoder backends.

---

## **Software Encoders** (Implemented ✅)

### **libx264 (H.264)**
- ✅ Encoder restart (instant bitrate change)
- ✅ Frame skipping (FPS reduction)
- ✅ HTTP control
- ✅ SRT automatic rate control
- ✅ Smart hysteresis
- ✅ Hybrid mode (frame skip + restart with FPS threshold)

**Why encoder restart?**  
`x264_encoder_reconfig()` doesn't reliably change bitrate at runtime. Encoder restart is the only method that works.

### **libx265 (HEVC)**
- ✅ Encoder restart (instant bitrate change)
- ✅ Frame skipping (instant FPS reduction)
- ✅ HTTP control
- ⏳ SRT automatic (not yet implemented)
- ⏳ Smart hysteresis (not yet implemented)

**Status**: Same as libx264, encoder restart works perfectly.

---

## **Hardware Encoders** (Native Support)

### **NVENC (NVIDIA)**
- ✅ **Native dynamic bitrate** via `NV_ENC_RECONFIGURE_PARAMS`
- ✅ No encoder restart needed
- ✅ Hardware-accelerated
- ⚠️ HTTP control not yet integrated

**Technical Details**:
```c
// NVENC already supports this natively!
NV_ENC_RECONFIGURE_PARAMS reconfig;
reconfig.reInitEncodeParams.encodeConfig->rcParams.averageBitRate = new_bitrate;
nvEncReconfigureEncoder(ctx->nvencoder, &reconfig);
```

**Supported via**:
- `avctx->bit_rate` changes (already works in FFmpeg)
- No need for encoder restart
- Smooth bitrate transitions

**To add HTTP control**:
1. Add `http_control_enable` option to nvenc
2. Check for commands in encode function
3. Update `avctx->bit_rate`
4. Let existing reconfig code handle it

**Estimated work**: 1-2 hours

### **VAAPI (Intel/AMD)**
- ✅ **Native rate control** via VAEncMiscParameterRateControl
- ✅ Hardware-accelerated
- ⚠️ HTTP control not yet integrated
- ⚠️ Encoder restart not needed (native support)

**Technical Details**:
```c
// VAAPI supports rate control updates
VAEncMiscParameterBuffer *misc_param;
VAEncMiscParameterRateControl *rate_ctrl;
// Update rate_ctrl->bits_per_second
vaRenderPicture(...);
```

**Supported via**:
- Rate control parameter buffers
- Can be updated per-frame
- No encoder restart needed

**To add HTTP control**:
1. Add HTTP control options
2. Update rate control params in encode function
3. Test on Intel/AMD hardware

**Estimated work**: 2-3 hours

### **VideoToolbox (macOS/iOS)**
- ✅ **Native dynamic bitrate** via `kVTCompressionPropertyKey_AverageBitRate`
- ✅ Hardware-accelerated (Apple Silicon, Intel)
- ⚠️ HTTP control not yet integrated

**Technical Details**:
```c
// VideoToolbox property setting
CFNumberRef bitrate = CFNumberCreate(..., new_bitrate);
VTSessionSetProperty(ctx->session, kVTCompressionPropertyKey_AverageBitRate, bitrate);
```

**Estimated work**: 1-2 hours

---

## **Implementation Roadmap**

### **Phase 1: Software Encoders** ✅ COMPLETE
- [x] libx264 encoder restart
- [x] libx264 frame skipping
- [x] libx264 HTTP control
- [x] libx264 SRT automatic
- [x] libx265 encoder restart
- [x] libx265 frame skipping
- [x] Smart hysteresis
- [x] Documentation

### **Phase 2: HTTP Control for Hardware** 🚧 Next
- [ ] NVENC HTTP control (use native reconfig)
- [ ] VAAPI HTTP control (use native rate control)
- [ ] VideoToolbox HTTP control (use native properties)
- [ ] Test on actual hardware

### **Phase 3: SRT Integration for Hardware** 💡 Future
- [ ] NVENC SRT automatic rate control
- [ ] VAAPI SRT automatic rate control
- [ ] VideoToolbox SRT automatic rate control
- [ ] Cross-platform testing

---

## **Why Different Approaches?**

| Encoder | Method | Reason |
|---------|--------|--------|
| **libx264/265** | Encoder restart | `*_encoder_reconfig()` unreliable |
| **NVENC** | Native reconfig | Hardware supports it natively |
| **VAAPI** | Native params | Driver handles rate control |
| **VideoToolbox** | Property update | macOS API design |

**Key Insight**: Hardware encoders have BETTER dynamic bitrate support than software encoders!

---

## **Next Steps for Hardware Support**

### **Quick Win: NVENC HTTP Control**

Since NVENC already has working dynamic bitrate, adding HTTP control is straightforward:

```c
// In nvenc_h264.c / nvenc_hevc.c
typedef struct NvencContext {
    // ... existing fields ...
    
    // Add HTTP control
    int http_control_enable;
    int http_control_port;
    int http_control_registered;
} NvencContext;

// In ff_nvenc_send_frame()
if (ctx->http_control_registered) {
    EncoderControlCommand cmd;
    if (encoder_control_get_command(ctx, &cmd)) {
        if (cmd.target_bitrate_kbps > 0) {
            avctx->bit_rate = cmd.target_bitrate_kbps * 1000LL;
            // Existing nvenc_reconfigure_encoder() will handle it
        }
    }
}
```

**Benefit**: Instant bitrate control with NO encoder restart, NO frame drop!

---

## **Recommendation**

**For Production Now**:
- Use libx264/libx265 with encoder restart (works on any hardware)

**For Future**:
- Prioritize NVENC HTTP control (most users have NVIDIA GPUs)
- Then VAAPI (Intel/AMD users)
- Then VideoToolbox (macOS users)

**Estimated total work for all hardware encoders**: 6-8 hours

---

**Status**: Software encoders complete, hardware encoder support planned
