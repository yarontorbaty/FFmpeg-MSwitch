/*
 * SRT Rate Control Demo
 * Demonstrates real-time adaptive bitrate encoding with SRT
 */

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libavcodec/srt_rate_control.h>
#include <stdio.h>
#include <stdlib.h>

static void encode_frame(AVCodecContext *enc_ctx, AVFrame *frame,
                        AVFormatContext *out_ctx, SRTRateControl *rc)
{
    int ret;
    AVPacket *pkt = av_packet_alloc();
    
    if (!pkt) {
        fprintf(stderr, "Failed to allocate packet\n");
        return;
    }
    
    // Update rate control before encoding
    if (rc) {
        srt_rc_update(rc);
        srt_rc_apply(rc);
    }
    
    ret = avcodec_send_frame(enc_ctx, frame);
    if (ret < 0) {
        fprintf(stderr, "Error sending frame to encoder: %s\n", av_err2str(ret));
        goto end;
    }
    
    while (ret >= 0) {
        ret = avcodec_receive_packet(enc_ctx, pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        } else if (ret < 0) {
            fprintf(stderr, "Error encoding frame: %s\n", av_err2str(ret));
            goto end;
        }
        
        // Write packet to output
        av_packet_rescale_ts(pkt, enc_ctx->time_base, out_ctx->streams[0]->time_base);
        pkt->stream_index = 0;
        
        ret = av_interleaved_write_frame(out_ctx, pkt);
        if (ret < 0) {
            fprintf(stderr, "Error writing packet: %s\n", av_err2str(ret));
            goto end;
        }
        
        av_packet_unref(pkt);
    }
    
end:
    av_packet_free(&pkt);
}

int main(int argc, char *argv[])
{
    const char *input_file, *output_url;
    AVFormatContext *in_ctx = NULL, *out_ctx = NULL;
    AVCodecContext *dec_ctx = NULL, *enc_ctx = NULL;
    const AVCodec *decoder, *encoder;
    AVFrame *frame = NULL;
    AVPacket *pkt = NULL;
    SRTRateControl *rc = NULL;
    int ret, video_stream_idx = -1;
    int64_t min_bitrate = 500000;   // 500 kbps
    int64_t max_bitrate = 10000000; // 10 Mbps
    
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <input_file> <srt_output_url> [min_bitrate] [max_bitrate]\n", argv[0]);
        fprintf(stderr, "Example: %s input.mp4 \"srt://localhost:4200?enable_stats=1\" 500000 10000000\n", argv[0]);
        return 1;
    }
    
    input_file = argv[1];
    output_url = argv[2];
    
    if (argc >= 4) min_bitrate = atoll(argv[3]);
    if (argc >= 5) max_bitrate = atoll(argv[4]);
    
    // Open input file
    ret = avformat_open_input(&in_ctx, input_file, NULL, NULL);
    if (ret < 0) {
        fprintf(stderr, "Failed to open input: %s\n", av_err2str(ret));
        return 1;
    }
    
    ret = avformat_find_stream_info(in_ctx, NULL);
    if (ret < 0) {
        fprintf(stderr, "Failed to find stream info: %s\n", av_err2str(ret));
        goto cleanup;
    }
    
    // Find video stream
    for (int i = 0; i < in_ctx->nb_streams; i++) {
        if (in_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            video_stream_idx = i;
            break;
        }
    }
    
    if (video_stream_idx < 0) {
        fprintf(stderr, "No video stream found\n");
        goto cleanup;
    }
    
    // Setup decoder
    decoder = avcodec_find_decoder(in_ctx->streams[video_stream_idx]->codecpar->codec_id);
    if (!decoder) {
        fprintf(stderr, "Failed to find decoder\n");
        goto cleanup;
    }
    
    dec_ctx = avcodec_alloc_context3(decoder);
    if (!dec_ctx) {
        fprintf(stderr, "Failed to allocate decoder context\n");
        goto cleanup;
    }
    
    avcodec_parameters_to_context(dec_ctx, in_ctx->streams[video_stream_idx]->codecpar);
    
    ret = avcodec_open2(dec_ctx, decoder, NULL);
    if (ret < 0) {
        fprintf(stderr, "Failed to open decoder: %s\n", av_err2str(ret));
        goto cleanup;
    }
    
    // Setup output
    ret = avformat_alloc_output_context2(&out_ctx, NULL, "mpegts", output_url);
    if (ret < 0) {
        fprintf(stderr, "Failed to allocate output context: %s\n", av_err2str(ret));
        goto cleanup;
    }
    
    // Setup encoder
    encoder = avcodec_find_encoder(AV_CODEC_ID_H264);
    if (!encoder) {
        fprintf(stderr, "H.264 encoder not found\n");
        goto cleanup;
    }
    
    enc_ctx = avcodec_alloc_context3(encoder);
    if (!enc_ctx) {
        fprintf(stderr, "Failed to allocate encoder context\n");
        goto cleanup;
    }
    
    enc_ctx->width = dec_ctx->width;
    enc_ctx->height = dec_ctx->height;
    enc_ctx->time_base = (AVRational){1, 25};
    enc_ctx->framerate = (AVRational){25, 1};
    enc_ctx->pix_fmt = AV_PIX_FMT_YUV420P;
    enc_ctx->bit_rate = (min_bitrate + max_bitrate) / 2;  // Start at midpoint
    enc_ctx->rc_max_rate = max_bitrate;
    enc_ctx->rc_buffer_size = max_bitrate * 2;
    enc_ctx->gop_size = 25;
    enc_ctx->max_b_frames = 0;  // Disable B-frames for low latency
    
    // Set encoder options for CBR
    av_opt_set(enc_ctx->priv_data, "preset", "veryfast", 0);
    av_opt_set(enc_ctx->priv_data, "tune", "zerolatency", 0);
    av_opt_set(enc_ctx->priv_data, "x264-params", "nal-hrd=cbr", 0);
    
    ret = avcodec_open2(enc_ctx, encoder, NULL);
    if (ret < 0) {
        fprintf(stderr, "Failed to open encoder: %s\n", av_err2str(ret));
        goto cleanup;
    }
    
    // Add stream to output
    AVStream *out_stream = avformat_new_stream(out_ctx, NULL);
    if (!out_stream) {
        fprintf(stderr, "Failed to create output stream\n");
        goto cleanup;
    }
    
    avcodec_parameters_from_context(out_stream->codecpar, enc_ctx);
    out_stream->time_base = enc_ctx->time_base;
    
    // Open output URL
    ret = avio_open(&out_ctx->pb, output_url, AVIO_FLAG_WRITE);
    if (ret < 0) {
        fprintf(stderr, "Failed to open output URL: %s\n", av_err2str(ret));
        goto cleanup;
    }
    
    ret = avformat_write_header(out_ctx, NULL);
    if (ret < 0) {
        fprintf(stderr, "Failed to write header: %s\n", av_err2str(ret));
        goto cleanup;
    }
    
    // Initialize SRT rate control
    rc = srt_rc_init(enc_ctx, min_bitrate, max_bitrate);
    if (!rc) {
        fprintf(stderr, "Failed to initialize SRT rate control\n");
        goto cleanup;
    }
    
    // Associate the output URL context with rate control
    if (out_ctx->pb && out_ctx->pb->opaque) {
        srt_rc_set_url_context(rc, out_ctx->pb->opaque);
    }
    
    printf("Starting adaptive bitrate encoding:\n");
    printf("  Input: %s\n", input_file);
    printf("  Output: %s\n", output_url);
    printf("  Bitrate range: %lld - %lld bps\n", min_bitrate, max_bitrate);
    printf("  Resolution: %dx%d\n", enc_ctx->width, enc_ctx->height);
    printf("\nPress Ctrl+C to stop...\n\n");
    
    // Encode loop
    pkt = av_packet_alloc();
    frame = av_frame_alloc();
    
    if (!pkt || !frame) {
        fprintf(stderr, "Failed to allocate packet/frame\n");
        goto cleanup;
    }
    
    while (av_read_frame(in_ctx, pkt) >= 0) {
        if (pkt->stream_index == video_stream_idx) {
            ret = avcodec_send_packet(dec_ctx, pkt);
            if (ret < 0) {
                fprintf(stderr, "Error sending packet to decoder: %s\n", av_err2str(ret));
                av_packet_unref(pkt);
                continue;
            }
            
            while (ret >= 0) {
                ret = avcodec_receive_frame(dec_ctx, frame);
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                    break;
                } else if (ret < 0) {
                    fprintf(stderr, "Error decoding frame: %s\n", av_err2str(ret));
                    break;
                }
                
                encode_frame(enc_ctx, frame, out_ctx, rc);
                av_frame_unref(frame);
            }
        }
        av_packet_unref(pkt);
    }
    
    // Flush encoder
    encode_frame(enc_ctx, NULL, out_ctx, rc);
    
    av_write_trailer(out_ctx);
    
    printf("\nEncoding complete!\n");
    if (rc) {
        printf("Rate control statistics:\n");
        printf("  Total adjustments: %d\n", rc->adjustment_count);
        printf("  Increases: %d\n", rc->increase_count);
        printf("  Decreases: %d\n", rc->decrease_count);
    }
    
cleanup:
    if (rc) srt_rc_free(rc);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    if (dec_ctx) avcodec_free_context(&dec_ctx);
    if (enc_ctx) avcodec_free_context(&enc_ctx);
    if (in_ctx) avformat_close_input(&in_ctx);
    if (out_ctx) {
        if (out_ctx->pb) avio_closep(&out_ctx->pb);
        avformat_free_context(out_ctx);
    }
    
    return 0;
}

