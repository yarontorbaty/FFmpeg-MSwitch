# Quick Test - Check if parse_mapping is called

Run this command and press `1` and `2` keys to switch:

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

**What to look for in terminal output:**

When you press `1`, you should see:
```
[MSwitch] Calling avfilter_process_command with map_str='1'
[StreamSelect] parse_mapping complete: nb_map=1, map[0]=1
[MSwitch] avfilter_process_command returned: 0 (success)
```

If you see `map[0]=1`, then the filter IS updating correctly, and the problem is elsewhere (possibly the framesync not respecting the new map).

If you DON'T see the `[StreamSelect] parse_mapping complete` message, then `process_command` isn't actually calling `parse_mapping`.

