/*
 * MSwitch video filter - multi-source video switcher
 * Copyright (c) 2025
 *
 * This file is part of FFmpeg.
 */

#include "libavutil/opt.h"
#include "libavutil/imgutils.h"
#include "libavutil/mem.h"
#include "libavutil/avstring.h"
#include "avfilter.h"
#include "filters.h"
#include "video.h"
#include "formats.h"



#define MAX_INPUTS 10

typedef struct MSwitchContext {
    const AVClass *class;
    
    int nb_inputs;
    int active_input;
    int last_input;
    int tube_size;          // Maximum frames to buffer per input
    int startup_phase;       // 1 during startup, 0 when all sources ingested
    int sources_ingested;    // Count of sources that have started producing frames
} MSwitchContext;

#define OFFSET(x) offsetof(MSwitchContext, x)
#define FLAGS AV_OPT_FLAG_VIDEO_PARAM|AV_OPT_FLAG_FILTERING_PARAM

static const AVOption mswitch_options[] = {
    { "inputs", "number of inputs", OFFSET(nb_inputs), AV_OPT_TYPE_INT, {.i64=2}, 2, MAX_INPUTS, FLAGS },
    { "map",    "input index to output", OFFSET(active_input), AV_OPT_TYPE_INT, {.i64=0}, 0, MAX_INPUTS-1, FLAGS },
    { "tube",   "maximum frames to buffer per input during startup", OFFSET(tube_size), AV_OPT_TYPE_INT, {.i64=5}, 1, 50, FLAGS },
    { NULL }
};

AVFILTER_DEFINE_CLASS(mswitch);

static int query_formats(const AVFilterContext *ctx,
                         AVFilterFormatsConfig **cfg_in,
                         AVFilterFormatsConfig **cfg_out)
{
    return ff_set_common_formats2(ctx, cfg_in, cfg_out, ff_formats_pixdesc_filter(0, 0));
}

static int config_output(AVFilterLink *outlink)
{
    AVFilterContext *ctx = outlink->src;
    MSwitchContext *s = ctx->priv;
    AVFilterLink *inlink = ctx->inputs[s->active_input];
    
    outlink->w = inlink->w;
    outlink->h = inlink->h;
    outlink->sample_aspect_ratio = inlink->sample_aspect_ratio;
    outlink->time_base = inlink->time_base;
    
    av_log(ctx, AV_LOG_INFO, "[MSwitch Filter] Configured: %dx%d, active_input=%d\n",
           outlink->w, outlink->h, s->active_input);
    
    return 0;
}

static int activate(AVFilterContext *ctx)
{
    MSwitchContext *s = ctx->priv;
    AVFilterLink *outlink = ctx->outputs[0];
    AVFrame *frame = NULL;
    int ret, i;
    static int debug_counter = 0;
    
    // Safety check
    if (s->active_input < 0 || s->active_input >= ctx->nb_inputs) {
        av_log(ctx, AV_LOG_ERROR, "[MSwitch Filter] Invalid active_input=%d (nb_inputs=%d)\n",
               s->active_input, ctx->nb_inputs);
        return AVERROR(EINVAL);
    }
    
    // Check if we're still in startup phase
    if (s->startup_phase) {
        // Count sources that have started producing frames
        s->sources_ingested = 0;
        for (i = 0; i < ctx->nb_inputs; i++) {
            if (ff_inlink_queued_frames(ctx->inputs[i]) > 0) {
                s->sources_ingested++;
            }
        }
        
        // Exit startup phase when all sources are producing frames
        if (s->sources_ingested >= ctx->nb_inputs) {
            s->startup_phase = 0;
            av_log(ctx, AV_LOG_INFO, "[MSwitch Filter] Startup phase complete - all %d sources ingested\n", ctx->nb_inputs);
        }
    }
    
    // Debug buffer sizes every 30 activations
    if (++debug_counter % 30 == 0) {
        av_log(ctx, AV_LOG_INFO, "[MSwitch Filter] Buffer Debug - Active input: %d, startup_phase: %d, sources_ingested: %d\n", 
               s->active_input, s->startup_phase, s->sources_ingested);
        for (i = 0; i < ctx->nb_inputs; i++) {
            int queued_frames = ff_inlink_queued_frames(ctx->inputs[i]);
            int status;
            int64_t status_pts;
            int has_status = ff_inlink_acknowledge_status(ctx->inputs[i], &status, &status_pts);
            av_log(ctx, AV_LOG_INFO, "[MSwitch Filter] Input %d: queued_frames=%d, has_status=%d, status=%d, wanted=%d\n", 
                   i, queued_frames, has_status, has_status ? status : 0, ff_outlink_frame_wanted(outlink));
        }
    }
    
    // Tube buffering: Limit frames per input during startup
    if (s->startup_phase) {
        for (i = 0; i < ctx->nb_inputs; i++) {
            int queued_frames = ff_inlink_queued_frames(ctx->inputs[i]);
            if (queued_frames > s->tube_size) {
                // Discard excess frames to maintain tube size
                int excess = queued_frames - s->tube_size;
                AVFrame *discard;
                int discarded = 0;
                while (ff_inlink_consume_frame(ctx->inputs[i], &discard) > 0 && discarded < excess) {
                    av_frame_free(&discard);
                    discarded++;
                }
                if (discarded > 0 && debug_counter % 30 == 0) {
                    av_log(ctx, AV_LOG_INFO, "[MSwitch Filter] Tube buffering: discarded %d excess frames from input %d\n", 
                           discarded, i);
                }
            }
        }
    }
    
    // Check if active input has changed
    if (s->active_input != s->last_input) {
        av_log(ctx, AV_LOG_INFO, "[MSwitch Filter] ⚡ Switched from input %d to input %d\n",
               s->last_input, s->active_input);
        s->last_input = s->active_input;
        
        // Clear any buffered frames from inactive inputs when switching
        for (i = 0; i < ctx->nb_inputs; i++) {
            if (i != s->active_input) {
                AVFrame *discard;
                int discarded = 0;
                while (ff_inlink_consume_frame(ctx->inputs[i], &discard) > 0) {
                    av_frame_free(&discard);
                    discarded++;
                }
                if (discarded > 0) {
                    av_log(ctx, AV_LOG_INFO, "[MSwitch Filter] Discarded %d frames from inactive input %d\n", 
                           discarded, i);
                }
            }
        }
    }
    
    // Only forward status from the active input to prevent buffering
    FF_FILTER_FORWARD_STATUS(ctx->inputs[s->active_input], outlink);
    
    // Try to get a frame from the active input
    ret = ff_inlink_consume_frame(ctx->inputs[s->active_input], &frame);
    if (ret < 0)
        return ret;
    
    if (frame) {
        av_log(ctx, AV_LOG_DEBUG, "[MSwitch Filter] Outputting frame from input %d, pts=%lld\n",
               s->active_input, frame->pts);
        
        return ff_filter_frame(outlink, frame);
    }
    
    // Aggressively discard frames from inactive inputs to prevent buffering
    for (i = 0; i < ctx->nb_inputs; i++) {
        if (i != s->active_input) {
            AVFrame *discard;
            int discarded = 0;
            // Discard multiple frames at once to clear buffers faster
            while (ff_inlink_consume_frame(ctx->inputs[i], &discard) > 0) {
                av_frame_free(&discard);
                discarded++;
            }
            if (discarded > 0 && debug_counter % 30 == 0) {
                av_log(ctx, AV_LOG_INFO, "[MSwitch Filter] Discarded %d frames from inactive input %d\n", 
                       discarded, i);
            }
        }
    }
    
    // Only request frames from the active input to prevent buffering inactive inputs
    FF_FILTER_FORWARD_WANTED(outlink, ctx->inputs[s->active_input]);
    
    return FFERROR_NOT_READY;
}

static av_cold int init(AVFilterContext *ctx)
{
    MSwitchContext *s = ctx->priv;
    int i, ret;
    
    av_log(ctx, AV_LOG_INFO, "[MSwitch Filter] Initializing with %d inputs, tube_size=%d\n", s->nb_inputs, s->tube_size);
    
    // Create input pads dynamically
    for (i = 0; i < s->nb_inputs; i++) {
        AVFilterPad pad = { 0 };
        
        pad.type = AVMEDIA_TYPE_VIDEO;
        pad.name = av_asprintf("input%d", i);
        if (!pad.name)
            return AVERROR(ENOMEM);
        
        if ((ret = ff_append_inpad_free_name(ctx, &pad)) < 0)
            return ret;
    }
    
    s->last_input = s->active_input;
    s->startup_phase = 1;  // Start in startup phase
    s->sources_ingested = 0;
    
    return 0;
}

static av_cold void uninit(AVFilterContext *ctx)
{
    av_log(ctx, AV_LOG_INFO, "[MSwitch Filter] Uninitialized\n");
}

static int process_command(AVFilterContext *ctx, const char *cmd, const char *arg,
                          char *res, int res_len, int flags)
{
    MSwitchContext *s = ctx->priv;
    int old_input = s->active_input;
    
    av_log(ctx, AV_LOG_WARNING, "[MSwitch Filter] Received command: %s = %s (current active=%d)\n", 
           cmd, arg, s->active_input);
    
    // Handle "map" command manually
    if (strcmp(cmd, "map") == 0) {
        int new_input = atoi(arg);
        
        if (new_input < 0 || new_input >= s->nb_inputs) {
            av_log(ctx, AV_LOG_ERROR, "[MSwitch Filter] Invalid map value: %d (must be 0-%d)\n",
                   new_input, s->nb_inputs - 1);
            return AVERROR(EINVAL);
        }
        
        s->active_input = new_input;
        
        if (old_input != s->active_input) {
            av_log(ctx, AV_LOG_WARNING, "[MSwitch Filter] ✅ Switched from input %d to input %d\n",
                   old_input, s->active_input);
        } else {
            av_log(ctx, AV_LOG_WARNING, "[MSwitch Filter] Already on input %d\n", s->active_input);
        }
        
        snprintf(res, res_len, "%d", s->active_input);
        return 0;
    }
    
    // Try default processing for other commands
    return ff_filter_process_command(ctx, cmd, arg, res, res_len, flags);
}

static const AVFilterPad mswitch_outputs[] = {
    {
        .name          = "default",
        .type          = AVMEDIA_TYPE_VIDEO,
        .config_props  = config_output,
    },
};

const FFFilter ff_vf_mswitch = {
    .p.name          = "mswitch",
    .p.description   = NULL_IF_CONFIG_SMALL("Multi-source video switcher"),
    .p.priv_class    = &mswitch_class,
    .p.flags         = AVFILTER_FLAG_DYNAMIC_INPUTS | AVFILTER_FLAG_SLICE_THREADS,
    .priv_size       = sizeof(MSwitchContext),
    .init            = init,
    .uninit          = uninit,
    .activate        = activate,
    FILTER_OUTPUTS(mswitch_outputs),
    FILTER_QUERY_FUNC2(query_formats),
    .process_command = process_command,
};
