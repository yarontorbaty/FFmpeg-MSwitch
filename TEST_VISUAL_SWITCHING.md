# Test Visual Switching - CRITICAL FIX APPLIED

## Critical Fix Applied
**Date**: January 2, 2025  
**Issue**: Visual switching wasn't working despite filter being updated  
**Root Cause**: Using `av_opt_set()` instead of `avfilter_process_command()` for runtime parameter changes

## The Fix
Changed from:
```c
int ret = av_opt_set(streamselect, "map", map_str, AV_OPT_SEARCH_CHILDREN);
```

To:
```c
char response[256] = {0};
int ret = avfilter_process_command(streamselect, "map", map_str, response, sizeof(response), 0);
```

## Why This Matters
The `streamselect` filter's `map` option is marked with `AV_OPT_FLAG_RUNTIME_PARAM`, meaning it can be changed at runtime. However, runtime parameter changes require using `avfilter_process_command()` which calls the filter's `process_command` callback, not just `av_opt_set()`.

From `libavfilter/f_streamselect.c`:
```c
static int process_command(AVFilterContext *ctx, const char *cmd, const char *args,
                           char *res, int res_len, int flags)
{
    if (!strcmp(cmd, "map")) {
        int ret = parse_mapping(ctx, args);
        if (ret < 0)
            return ret;
        return 0;
    }
    return AVERROR(ENOSYS);
}
```

This function re-parses the mapping and updates the internal `map` array, which is what actually controls which input is routed to which output.

## Test Command
```bash
cd /Users/yarontorbaty/Documents/Code/FFmpeg

# Cleanup
pkill -9 ffmpeg ffplay 2>/dev/null
sleep 1

# Start FFmpeg with MSwitch
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

## Testing Steps
1. Run the command above
2. ffplay window opens showing **RED** screen
3. Click on the **TERMINAL** window (where FFmpeg is running)
4. Press `1` key → Screen should turn **GREEN**
5. Press `2` key → Screen should turn **BLUE**
6. Press `0` key → Screen should turn **RED** again
7. Press `q` to quit

## Expected Debugging Output
When you press `1`, you should see:
```
[MSwitch] Switch request: target=1 (s1), current=0
[MSwitch] Switching from source 0 to source 1 (s1)
[MSwitch] Performing graceful switch to source 1
[MSwitch] >>> mswitch_update_filter_map called: target_index=1, streamselect=0x...
[MSwitch] streamselect filter name: streamselect
[MSwitch] Calling avfilter_process_command with map_str='1'
[MSwitch] avfilter_process_command returned: 0 (success), response=''
[MSwitch] ✓ Filter updated and verified: streamselect map='1' (expected '1')
```

## Success Criteria
- ✅ ffplay window changes color immediately when keys are pressed
- ✅ Debugging shows `avfilter_process_command returned: 0 (success)`
- ✅ No errors or warnings about filter updates
- ✅ Can switch rapidly (0→1→2→0→1...) without issues
- ✅ No crashes or memory errors

## If This Works
This confirms that:
1. Filter-based switching is the correct approach
2. The MSwitch integration with FFmpeg's filter system is working
3. We can proceed to:
   - Fix webhook threading issues
   - Add automated visual testing
   - Test with real UDP/RTMP/SRT sources
   - Document the solution

## If This Still Doesn't Work
We need to investigate:
1. Whether `avfilter_process_command` is actually being called during playback
2. Whether the filter graph is locked/frozen during encoding
3. Whether we need to flush/reset the filter pipeline
4. Alternative approaches (e.g., using `sendcmd` filter)

---

*Test Plan Created: January 2, 2025*  
*This is the most critical test - if visual switching works now, the core implementation is validated.*

