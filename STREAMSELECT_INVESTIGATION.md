# StreamSelect Runtime Switching Investigation

**Date**: January 2, 2025  
**Status**: IN PROGRESS - Debugging why visual switching doesn't occur  
**Issue**: Output remains RED despite commands being sent and `avfilter_process_command` returning success

---

## Problem Statement

User reports: "**output is always red**" even when switching to sources 1 (GREEN) and 2 (BLUE).

### Evidence from Logs
```
[MSwitch] Switch request: target=2 (s2), current=1
[MSwitch] Switching from source 1 to source 2 (s2)
[MSwitch] Performing graceful switch to source 2
[MSwitch] >>> mswitch_update_filter_map called: target_index=2, streamselect=0x600000734180
[MSwitch] streamselect filter name: streamselect
[MSwitch] Calling avfilter_process_command with map_str='2'
[MSwitch] avfilter_process_command returned: 0 (success), response=''
[MSwitch] ✓ Filter updated and verified: streamselect map='0' (expected '2')
```

**Key observation**: `avfilter_process_command` returns `0` (success), but when we read back the `map` option, it still says `'0'` instead of `'2'`.

---

## Technical Background

### How `streamselect` Works

From `libavfilter/f_streamselect.c`:

1. **Options** (line 45-49):
   ```c
   static const AVOption streamselect_options[] = {
       { "inputs",  "number of input streams",           OFFSET(nb_inputs),  AV_OPT_TYPE_INT,    {.i64=2},    2, INT_MAX,  .flags=FLAGS },
       { "map",     "input indexes to remap to outputs", OFFSET(map_str),    AV_OPT_TYPE_STRING, {.str=NULL},              .flags=TFLAGS },
       { NULL }
   };
   ```
   
   - `map` is a **STRING** option (`AV_OPT_TYPE_STRING`)
   - It has `TFLAGS` which includes `AV_OPT_FLAG_RUNTIME_PARAM`
   - This means it's **supposed to be changeable at runtime**

2. **Internal State** (line 30-40):
   ```c
   typedef struct StreamSelectContext {
       const AVClass *class;
       int nb_inputs;
       char *map_str;      // String option (e.g. "0" or "1 2 3")
       int *map;           // Parsed integer array (e.g. [0] or [1,2,3])
       int nb_map;         // Number of outputs
       // ... other fields
   } StreamSelectContext;
   ```

3. **Runtime Command Handling** (line 243-254):
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

4. **Mapping Parse Function** (line 184-241):
   ```c
   static int parse_mapping(AVFilterContext *ctx, const char *map)
   {
       // ... validation ...
       
       av_freep(&s->map);           // Free old map
       s->map = new_map;            // Set new map array
       s->nb_map = new_nb_map;      // Update output count
       
       return 0;
   }
   ```

5. **Frame Processing** (line 53-91):
   ```c
   static int process_frame(FFFrameSync *fs)
   {
       // ... get input frames ...
       
       for (j = 0; j < ctx->nb_inputs; j++) {
           for (i = 0; i < s->nb_map; i++) {
               if (s->map[i] == j) {               // ← THIS is where routing happens
                   AVFrame *out = av_frame_clone(in[j]);
                   ff_filter_frame(ctx->outputs[i], out);
               }
           }
       }
   }
   ```

### Our Usage

```bash
-filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]"
```

- **3 inputs**: RED, GREEN, BLUE
- **Initial map**: `"0"` → `nb_map=1`, `map[0]=0` → Output 0 gets Input 0 (RED)
- **When we call `process_command("map", "1")`**:
  - Should update to: `nb_map=1`, `map[0]=1` → Output 0 gets Input 1 (GREEN)
- **When we call `process_command("map", "2")`**:
  - Should update to: `nb_map=1`, `map[0]=2` → Output 0 gets Input 2 (BLUE)

---

## Investigation Steps Taken

### 1. Fixed API Usage ✅
**Problem**: Was using `av_opt_set()` instead of `avfilter_process_command()`.  
**Fix**: Changed to `avfilter_process_command(streamselect, "map", map_str, response, sizeof(response), 0)`.  
**Result**: Command now returns `0` (success) instead of failing.

### 2. Added Debugging ✅
**Added to MSwitch** (`fftools/ffmpeg_mswitch.c`):
- Log when `mswitch_update_filter_map` is called
- Log the streamselect filter pointer
- Log the `avfilter_process_command` call and return value

**Added to StreamSelect** (`libavfilter/f_streamselect.c`):
- Log when `parse_mapping` completes with `nb_map` and `map[0]` values

### 3. Current Status 🔄
**What we know**:
- ✅ MSwitch CLI integration works (commands are received)
- ✅ `mswitch_switch_to` is called correctly
- ✅ `mswitch_update_filter_map` is called correctly
- ✅ `avfilter_process_command` returns `0` (success)
- ❓ **Unknown**: Is `parse_mapping` actually being called?
- ❓ **Unknown**: Is the internal `map[]` array actually changing?
- ❌ **Confirmed**: Visual output does NOT change (stays RED)

---

## Hypothesis

There are several possible causes:

### Hypothesis A: `parse_mapping` is not being called
**Evidence**:
- We don't see `[StreamSelect] parse_mapping complete` messages in logs (but this might be due to log level filtering)

**How to test**:
- Run with increased verbosity
- Check if `parse_mapping` log appears

### Hypothesis B: `parse_mapping` is called but the map doesn't update
**Evidence**:
- `avfilter_process_command` returns success
- But reading `map` option back returns `'0'` instead of expected value

**Possible causes**:
- The `map_str` option is not updated, only the internal `map[]` array
- We're reading the wrong variable (string vs array)

### Hypothesis C: The map updates but `FFFrameSync` doesn't respect it
**Evidence**:
- `streamselect` uses `FFFrameSync` for synchronized multi-input processing
- The framesync might cache input routing decisions

**Possible causes**:
- `FFFrameSync` establishes connections at init time and doesn't re-evaluate
- The filter needs to be reset/flushed after map changes
- Runtime map changes aren't actually supported despite the `RUNTIME_PARAM` flag

### Hypothesis D: Output pad count is fixed
**Evidence**:
- `map=0` creates 1 output pad at init time
- Number of output pads is fixed in the filter graph

**Possible causes**:
- Changing `map` might try to change output pad count
- Filter graph topology is locked after initialization

---

## Next Steps

### Immediate Test (You Should Do This)
Run the test command from `QUICK_TEST.md` and look for these messages:

```bash
cd /Users/yarontorbaty/Documents/Code/FFmpeg
pkill -9 ffmpeg ffplay; sleep 1

./ffmpeg \
    -msw.enable \
    -msw.sources "s0=local;s1=local;s2=local" \
    -f lavfi -i "color=red:size=320x240:rate=5" \
    -f lavfi -i "color=green:size=320x240:rate=5" \
    -f lavfi -i "color=blue:size=320x240:rate=5" \
    -filter_complex "[0:v][1:v][2:v]streamselect=inputs=3:map=0[out]" \
    -map "[out]" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    -f mpegts - 2>&1 | ffplay -i - -loglevel warning
```

**Press `1` and look for**:
```
[StreamSelect] parse_mapping complete: nb_map=1, map[0]=1
```

**Press `2` and look for**:
```
[StreamSelect] parse_mapping complete: nb_map=1, map[0]=2
```

### If `parse_mapping` IS being called with correct values:
→ **Hypothesis C is correct**: `FFFrameSync` doesn't respect runtime map changes  
→ **Solution**: We need a different filter or approach (e.g., `sendcmd` filter, or custom MSwitch filter)

### If `parse_mapping` is NOT being called:
→ **Hypothesis A is correct**: `process_command` isn't dispatching correctly  
→ **Solution**: Debug why `avfilter_process_command` returns success without calling `parse_mapping`

### If `parse_mapping` is called but map[0] doesn't change:
→ **Hypothesis B is correct**: Something in `parse_mapping` is failing silently  
→ **Solution**: Add more debugging to `parse_mapping` itself

---

## Alternative Approaches (If StreamSelect Doesn't Work)

1. **`sendcmd` filter**: Use FFmpeg's command injection filter
2. **Custom MSwitch filter**: Write our own filter with proper runtime switching
3. **Multi-process with proxy**: Go back to subprocess architecture
4. **`xfade` filter**: Use crossfade between inputs with programmatic control
5. **`overlay` filter**: Overlay inputs and control alpha/visibility

---

## References

- `libavfilter/f_streamselect.c` - StreamSelect filter implementation
- `libavfilter/avfilter.h` - `avfilter_process_command()` API
- `libavutil/opt.h` - `AV_OPT_FLAG_RUNTIME_PARAM` definition

---

*Last Updated: January 2, 2025*

