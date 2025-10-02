# MSwitch Interactive CLI Testing Guide

## Overview

This guide explains how to test the MSwitch filter-based switching implementation using the **interactive CLI** (keyboard commands). The webhook has threading issues, so the interactive CLI is the recommended method for source switching.

## Why Interactive CLI?

- ✅ **Thread-safe**: Runs in main thread, no race conditions
- ✅ **Immediate response**: Direct keyboard input handling
- ✅ **Simple**: No HTTP server overhead
- ✅ **Reliable**: No bus errors or memory corruption
- ✅ **Visual feedback**: See switching messages in real-time

## Test Setup

### Automated Test Script

```bash
cd /Users/yarontorbaty/Documents/Code/FFmpeg
./tests/test_interactive_cli.sh
```

This script will:
1. Start FFmpeg with MSwitch enabled
2. Open ffplay showing RED screen initially
3. Provide instructions for keyboard testing
4. Wait for you to test switching

### Manual Test Command

```bash
./ffmpeg \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local" \
    -f lavfi -i "color=red:size=640x480:rate=10" \
    -f lavfi -i "color=green:size=640x480:rate=10" \
    -f lavfi -i "color=blue:size=640x480:rate=10" \
    -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -g 50 -pix_fmt yuv420p \
    -f mpegts - | ffplay -i -
```

## How to Test

### Step 1: Start FFmpeg
Run the command above. You should see:
- FFmpeg initialization messages
- MSwitch messages: "Filter-based switching initialized"
- ffplay window opens showing RED screen

### Step 2: Focus the Terminal
**IMPORTANT**: Click on the terminal window where FFmpeg is running. This ensures keyboard input goes to FFmpeg, not ffplay.

### Step 3: Test Switching
Press these keys in the terminal:

| Key | Action | Expected Result |
|-----|--------|----------------|
| `0` | Switch to source 0 | ffplay shows RED |
| `1` | Switch to source 1 | ffplay shows GREEN |
| `2` | Switch to source 2 | ffplay shows BLUE |
| `m` | Show MSwitch status | Prints active source info |
| `?` | Show help | Lists available commands |
| `q` | Quit | FFmpeg exits |

### Step 4: Verify Output
In the terminal, you should see messages like:
```
[MSwitch] Switch request: target=1 (s1), current=0
[MSwitch] Switching from source 0 to source 1 (s1)
[MSwitch] Performing graceful switch to source 1
[MSwitch] Updating streamselect filter: map=1 (filter=0x...)
[MSwitch] ✓ Filter updated: streamselect map=1
```

### Step 5: Visual Verification
- Press `1` → Screen turns GREEN instantly
- Press `2` → Screen turns BLUE instantly
- Press `0` → Screen turns RED instantly

## Expected Behavior

### ✅ Success Indicators
- ffplay window color changes immediately when keys are pressed
- Terminal shows switching messages with correct source numbers
- No crashes or errors
- Smooth transitions between colors

### ❌ Failure Indicators
- ffplay window doesn't change color
- Terminal shows errors like "Failed to update streamselect map"
- FFmpeg crashes
- Colors are wrong (e.g., pressing `1` shows BLUE instead of GREEN)

## Troubleshooting

### Problem: Key presses don't do anything

**Solution**: Make sure the terminal window (not ffplay) is focused. Click on the terminal and try again.

### Problem: ffplay doesn't show anything

**Solution**: 
1. Check if ffplay is installed: `which ffplay`
2. Try with null output first to verify FFmpeg works:
   ```bash
   ./ffmpeg -msw.enable -msw.sources "s0=local;s1=local;s2=local" \
     -f lavfi -i "color=red:size=320x240:rate=10" \
     -f lavfi -i "color=green:size=320x240:rate=10" \
     -f lavfi -i "color=blue:size=320x240:rate=10" \
     -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
     -map "[out]" -t 5 -f null -
   ```

### Problem: "streamselect filter not initialized"

**Solution**: Make sure you're using the `-filter_complex` with `streamselect`. The filter must be present for MSwitch to attach to it.

### Problem: FFmpeg crashes with "bus error"

**Solution**: Make sure you're NOT using `-msw.webhook.enable`. The webhook has threading issues. Interactive CLI only!

## Testing with Real Sources

Once interactive CLI switching works with `color` sources, test with real UDP sources:

```bash
# Terminal 1: Start sources
./ffmpeg -re -f lavfi -i testsrc=size=640x480:rate=30 \
  -c:v libx264 -preset ultrafast -f mpegts udp://127.0.0.1:12346 &

./ffmpeg -re -f lavfi -i testsrc2=size=640x480:rate=30 \
  -c:v libx264 -preset ultrafast -f mpegts udp://127.0.0.1:12347 &

./ffmpeg -re -f lavfi -i smptebars=size=640x480:rate=30 \
  -c:v libx264 -preset ultrafast -f mpegts udp://127.0.0.1:12348 &

# Terminal 2: Start MSwitch
./ffmpeg \
    -msw.enable \
    -msw.sources "s0=udp://127.0.0.1:12346;s1=udp://127.0.0.1:12347;s2=udp://127.0.0.1:12348" \
    -i udp://127.0.0.1:12346 \
    -i udp://127.0.0.1:12347 \
    -i udp://127.0.0.1:12348 \
    -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -g 50 -pix_fmt yuv420p \
    -f mpegts - | ffplay -i -

# Press 0, 1, 2 to switch between test patterns
```

## Integration with check_keyboard_interaction

The interactive CLI commands are integrated into FFmpeg's existing `check_keyboard_interaction()` function in `fftools/ffmpeg.c`:

```c
case '0': case '1': case '2':
    if (global_mswitch_enabled && global_mswitch_ctx.nb_sources > 0) {
        int source_num = key - '0';
        if (source_num < global_mswitch_ctx.nb_sources) {
            char source_id[8];
            snprintf(source_id, sizeof(source_id), "s%d", source_num);
            mswitch_switch_to(&global_mswitch_ctx, source_id);
        }
    }
    break;

case 'm':
    if (global_mswitch_enabled) {
        av_log(NULL, AV_LOG_INFO, 
               "[MSwitch] Status: Active source = %d (%s), Total sources = %d\n",
               global_mswitch_ctx.active_source_index,
               global_mswitch_ctx.sources[global_mswitch_ctx.active_source_index].id,
               global_mswitch_ctx.nb_sources);
    }
    break;
```

## Test Checklist

Use this checklist when testing:

- [ ] FFmpeg starts without errors
- [ ] MSwitch initializes: "Filter-based switching initialized"
- [ ] streamselect filter detected and connected
- [ ] Initial source is 0 (RED)
- [ ] Pressing `1` switches to GREEN visually
- [ ] Terminal shows: "Switching from source 0 to source 1"
- [ ] Terminal shows: "✓ Filter updated: streamselect map=1"
- [ ] Pressing `2` switches to BLUE visually
- [ ] Pressing `0` switches back to RED visually
- [ ] Pressing `m` shows status with correct active source
- [ ] No errors or warnings in terminal
- [ ] No crashes or freezes
- [ ] Can switch rapidly (0→1→2→0) without issues
- [ ] Pressing `q` exits cleanly

## Success Criteria

The implementation is **WORKING** if:
1. ✅ All keys (0, 1, 2) trigger immediate visual changes in ffplay
2. ✅ Terminal logs show correct switching messages
3. ✅ No crashes, errors, or memory issues
4. ✅ Can switch rapidly without problems
5. ✅ Clean exit with `q` key

## Next Steps After Successful Testing

Once interactive CLI switching is verified:
1. Document the working solution
2. Update user documentation with CLI commands
3. Fix webhook threading issues (message queue pattern)
4. Add automated visual verification tests
5. Test with production sources (RTMP, SRT, UDP streams)

---

*Test Guide Created: January 2, 2025*
*FFmpeg Version: N-121297-g0c97cbeb22*

