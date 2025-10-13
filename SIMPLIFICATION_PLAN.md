# SRT Rate Control Simplification Plan

## Current Status
The SRT rate control code is overly complex (~200 lines) with mixed approaches:
- VBV reconfig (doesn't work reliably)
- Frame skipping  
- Encoder restart
- Aggressive mode
- Dynamic VBV sizing

## Simplification Goals

### REMOVE:
- ❌ Graceful VBV reconfig (x264_encoder_reconfig) - unreliable
- ❌ Dynamic VBV buffer sizing - unnecessary with restart
- ❌ Aggressive mode - redundant
- ❌ Complex GOP adjustment - not needed

### KEEP:
- ✅ Encoder restart (instant, works perfectly)
- ✅ Frame skipping (for extreme bitrate drops)
- ✅ Smart hysteresis (instant down, delayed up)
- ✅ min_fps_before_restart threshold

## New Logic (Simplified)

```
if (bandwidth changed significantly):
    if (downshift):
        apply INSTANTLY ⚡
    else (upshift):
        if (delay expired and health checks passed):
            apply ✓
        else:
            wait 🕒
    
    if (enable_frame_skip && FPS > min_fps_before_restart):
        use frame skipping
    else if (enable_encoder_restart):
        restart encoder
    else:
        warn user
```

## Implementation Steps

1. Replace lines 827-1027 with clean logic (~50 lines)
2. Remove unused VBV reconfig code
3. Simplify to: restart OR skip, nothing else
4. Update all documentation

## Expected Result

- Clean, maintainable code
- Only methods that WORK
- ~75% code reduction
- Same functionality, better reliability

