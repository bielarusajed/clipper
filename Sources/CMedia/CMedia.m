#import "CMedia.h"
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libavutil/hwcontext.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <stdatomic.h>

struct ClipRequest { atomic_int generation; };
ClipRequest *clip_request_create(void) { ClipRequest *r=calloc(1,sizeof(*r)); atomic_init(&r->generation,0); return r; }
void clip_request_free(ClipRequest *r) { free(r); }
void clip_request_set(ClipRequest *r,int generation) { atomic_store(&r->generation,generation); }

struct ClipMedia {
    AVFormatContext *format;
    AVCodecContext *video, *audio;
    int vi, ai;
    AVFrame *frame;
    AVPacket *packet;
    int receiving, eof, videoDrained, audioDrained;
    struct SwsContext *sws;
    SwrContext *swr;
    ClipInfo info;
    int audioStreams[64];
    char audioLabels[64][160];
    double audioFloor;
    ClipSample cache[12];
    int confirmed[12], cacheEnabled, cacheSlot;
    double lastDecoded;
    AVFrame *rawCache[12];
    double rawTime[12], rawDuration[12];
    int rawConfirmed[12], rawSlot, lastRaw;
};

static void message(char *out, int size, int code) { av_strerror(code, out, size); }
static enum AVPixelFormat hardwareFormat(AVCodecContext *ctx, const enum AVPixelFormat *formats) {
    for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    return formats[0];
}
static AVCodecContext *decoder(AVFormatContext *f, int i, int hardware) {
    const AVCodec *codec = avcodec_find_decoder(f->streams[i]->codecpar->codec_id);
    if (!codec) return NULL;
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return NULL;
    avcodec_parameters_to_context(ctx, f->streams[i]->codecpar);
    ctx->pkt_timebase = f->streams[i]->time_base;
    ctx->thread_count = hardware && ctx->width >= 2560 ? 8 : 4;
    if (hardware) {
        for (int n = 0;; n++) {
            const AVCodecHWConfig *config = avcodec_get_hw_config(codec, n);
            if (!config) break;
            if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
                (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
                if (av_hwdevice_ctx_create(&ctx->hw_device_ctx, config->device_type, NULL, NULL, 0) == 0)
                    ctx->get_format = hardwareFormat;
                break;
            }
        }
    }
    if (avcodec_open2(ctx, codec, NULL) < 0) { avcodec_free_context(&ctx); return NULL; }
    return ctx;
}

ClipMedia *clip_open(const char *path, int audioTrack, char *error, int errorSize) {
    av_log_set_level(AV_LOG_ERROR);
    ClipMedia *m = calloc(1, sizeof(*m));
    m->lastDecoded=NAN;
    m->lastRaw=-1;
    m->ai = -1;
    int rc = avformat_open_input(&m->format, path, NULL, NULL);
    if (rc < 0) goto fail;
    rc = avformat_find_stream_info(m->format, NULL);
    if (rc < 0) goto fail;
    m->vi = av_find_best_stream(m->format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (m->vi < 0) { rc = m->vi; goto fail; }
    AVStream *v = m->format->streams[m->vi];
    AVCodecParameters *p = v->codecpar;
    m->info.width = p->width; m->info.height = p->height;
    m->info.origin = m->format->start_time == AV_NOPTS_VALUE ? 0 : (double)m->format->start_time / AV_TIME_BASE;
    m->info.duration = m->format->duration == AV_NOPTS_VALUE ? 0 : (double)m->format->duration / AV_TIME_BASE;
    if (m->info.duration <= 0 && v->duration != AV_NOPTS_VALUE) m->info.duration = v->duration * av_q2d(v->time_base);
    AVRational rate = av_guess_frame_rate(m->format, v, NULL);
    m->info.fps = rate.num ? av_q2d(rate) : 30;
    AVRational sar = av_guess_sample_aspect_ratio(m->format, v, NULL);
    m->info.pixelAspect = sar.num ? av_q2d(sar) : 1;
    m->info.hdr = p->color_trc == AVCOL_TRC_SMPTE2084 || p->color_trc == AVCOL_TRC_ARIB_STD_B67;
    const AVPacketSideData *side = av_packet_side_data_get(p->coded_side_data, p->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (side && side->size >= 9 * sizeof(int32_t)) { m->info.rotation = -av_display_rotation_get((const int32_t *)side->data); }
    snprintf(m->info.codec, sizeof(m->info.codec), "%s", avcodec_get_name(p->codec_id));
    for (unsigned i = 0; i < m->format->nb_streams && m->info.audioCount < 64; i++) {
        AVStream *s = m->format->streams[i];
        if (s->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        int n = m->info.audioCount++;
        m->audioStreams[n] = i;
        AVDictionaryEntry *lang = av_dict_get(s->metadata, "language", NULL, 0);
        AVDictionaryEntry *title = av_dict_get(s->metadata, "title", NULL, 0);
        snprintf(m->audioLabels[n], 160, "%d. %s%s%s (%s)", n+1, lang ? lang->value : "Audio", title ? " / " : "", title ? title->value : "", avcodec_get_name(s->codecpar->codec_id));
    }
    m->video = decoder(m->format, m->vi, 1);
    if (!m->video) { rc = AVERROR_DECODER_NOT_FOUND; goto fail; }
    if (audioTrack >= 0 && audioTrack < m->info.audioCount) {
        m->ai = m->audioStreams[audioTrack];
        m->audio = decoder(m->format, m->ai, 0);
        if (!m->audio) { rc = AVERROR_DECODER_NOT_FOUND; goto fail; }
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        rc = swr_alloc_set_opts2(&m->swr, &stereo, AV_SAMPLE_FMT_FLT, 48000,
                               &m->audio->ch_layout, m->audio->sample_fmt, m->audio->sample_rate, 0, NULL);
        if (rc < 0 || (rc = swr_init(m->swr)) < 0) goto fail;
    }
    m->frame = av_frame_alloc(); m->packet = av_packet_alloc();
    return m;
fail:
    message(error, errorSize, rc); clip_close(m); return NULL;
}
void clip_close(ClipMedia *m) {
    if (!m) return;
    for (int i=0;i<12;i++) if (m->cache[i].sample) CFRelease(m->cache[i].sample);
    for (int i=0;i<12;i++) av_frame_free(&m->rawCache[i]);
    avformat_close_input(&m->format);
    avcodec_free_context(&m->video); avcodec_free_context(&m->audio);
    av_frame_free(&m->frame); av_packet_free(&m->packet);
    sws_freeContext(m->sws); swr_free(&m->swr); free(m);
}
ClipInfo clip_info(ClipMedia *m) { return m->info; }
const char *clip_audio_label(ClipMedia *m, int track) { return m->audioLabels[track]; }
int clip_audio_stream(ClipMedia *m, int track) { return m->audioStreams[track]; }
int clip_seek(ClipMedia *m, double time) {
    // AVI demuxers may choose the following keyframe at a rounded seek boundary.
    // Decode preroll and choose by presentation timestamp rather than trusting it.
    double preroll = !strcmp(m->format->iformat->name,"avi") ? 1.0 : 0;
    int64_t timestamp = (int64_t)((fmax(0,time-preroll) + m->info.origin) * AV_TIME_BASE);
    int rc = avformat_seek_file(m->format, -1, INT64_MIN, timestamp, timestamp, AVSEEK_FLAG_BACKWARD);
    if (rc < 0) return rc;
    avcodec_flush_buffers(m->video);
    if (m->audio) avcodec_flush_buffers(m->audio);
    if (m->swr) { swr_close(m->swr); swr_init(m->swr); }
    av_packet_unref(m->packet);
    m->receiving = 0; m->eof = 0; m->videoDrained = 0; m->audioDrained = 0;
    m->audioFloor = time;
    m->lastDecoded=NAN;
    m->lastRaw=-1;
    return 0;
}
void clip_enable_cache(ClipMedia *m) { m->cacheEnabled=1; }
static void cacheFrame(ClipMedia *m, ClipSample s) {
    if (!m->cacheEnabled || s.kind!=1) return;
    int existing=-1;
    for (int i=0;i<12;i++) {
        if (!m->cache[i].sample) continue;
        if (fabs(m->cache[i].time-m->lastDecoded)<0.0000001 && s.time > m->lastDecoded) {
            m->cache[i].duration=s.time-m->lastDecoded; m->confirmed[i]=1;
        }
        if (fabs(m->cache[i].time-s.time)<0.0000001) existing=i;
    }
    m->lastDecoded=s.time;
    if (existing>=0) return;
    int slot=m->cacheSlot++%12;
    if (m->cache[slot].sample) CFRelease(m->cache[slot].sample);
    m->cache[slot]=s; CFRetain(s.sample); m->confirmed[slot]=0;
}

static CFStringRef primaries(enum AVColorPrimaries p) {
    return p == AVCOL_PRI_BT2020 ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2;
}
static ClipSample videoSample(ClipMedia *m, AVFrame *f) {
    CVPixelBufferRef pixel = NULL;
    if (f->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        pixel = (CVPixelBufferRef)f->data[3]; CVPixelBufferRetain(pixel);
    } else {
        BOOL ten = m->info.hdr;
        OSType format = ten ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (CVPixelBufferCreate(NULL, f->width, f->height, format, (__bridge CFDictionaryRef)attrs, &pixel) != kCVReturnSuccess) return (ClipSample){.kind=-1};
        CVPixelBufferLockBaseAddress(pixel, 0);
        enum AVPixelFormat dest = ten ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
        m->sws = sws_getCachedContext(m->sws, f->width, f->height, f->format, f->width, f->height, dest, SWS_BILINEAR, NULL, NULL, NULL);
        if (!m->sws) { CVPixelBufferUnlockBaseAddress(pixel, 0); CVPixelBufferRelease(pixel); return (ClipSample){.kind=-1}; }
        uint8_t *data[4] = {0}; int strides[4] = {0};
        for (int n=0;n<2;n++) { data[n] = CVPixelBufferGetBaseAddressOfPlane(pixel,n); strides[n] = (int)CVPixelBufferGetBytesPerRowOfPlane(pixel,n); }
        sws_scale(m->sws, (const uint8_t * const *)f->data, f->linesize, 0, f->height, data, strides);
        CVPixelBufferUnlockBaseAddress(pixel, 0);
    }
    CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, primaries(f->color_primaries), kCVAttachmentMode_ShouldPropagate);
    CFStringRef transfer = f->color_trc == AVCOL_TRC_SMPTE2084 ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : f->color_trc == AVCOL_TRC_ARIB_STD_B67 ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2;
    CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, transfer, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, m->info.hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    AVStream *s = m->format->streams[m->vi];
    int64_t pts = f->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) { CVPixelBufferRelease(pixel); return (ClipSample){.kind=-1}; }
    double t = pts * av_q2d(s->time_base) - m->info.origin;
    double duration = f->duration > 0 ? f->duration * av_q2d(s->time_base) : 1.0 / m->info.fps;
    CMSampleTimingInfo timing = { CMTimeMakeWithSeconds(duration, 1000000), CMTimeMakeWithSeconds(t, 1000000), kCMTimeInvalid };
    CMVideoFormatDescriptionRef desc = NULL;
    CMSampleBufferRef sample = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixel, &desc);
    OSStatus rc = CMSampleBufferCreateReadyWithImageBuffer(NULL, pixel, desc, &timing, &sample);
    if (desc) CFRelease(desc); CVPixelBufferRelease(pixel);
    return (ClipSample){sample,t,duration,pts,s->time_base.num,s->time_base.den,rc == 0 ? 1 : -1};
}
static ClipSample audioSample(ClipMedia *m, AVFrame *f) {
    AVStream *s = m->format->streams[m->ai];
    int64_t pts = f->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) return (ClipSample){.kind=-2};
    double t = pts * av_q2d(s->time_base) - m->info.origin;
    int capacity = (int)av_rescale_rnd(swr_get_delay(m->swr,m->audio->sample_rate)+f->nb_samples,48000,m->audio->sample_rate,AV_ROUND_UP);
    float *data = malloc(capacity * 2 * sizeof(float));
    uint8_t *out = (uint8_t *)data;
    int count = swr_convert(m->swr, &out, capacity, (const uint8_t **)f->extended_data, f->nb_samples);
    int skip = (int)ceil(fmax(0, m->audioFloor-t)*48000);
    if (count <= skip) { free(data); return (ClipSample){.kind=-2}; }
    t += (double)skip/48000; count -= skip;
    size_t bytes = count * 2 * sizeof(float);
    AudioStreamBasicDescription asbd = {48000,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,8,1,8,2,32,0};
    CMAudioFormatDescriptionRef desc = NULL;
    CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &desc);
    CMBlockBufferRef block = NULL;
    CMBlockBufferCreateWithMemoryBlock(NULL,NULL,bytes,NULL,NULL,0,bytes,0,&block);
    CMBlockBufferReplaceDataBytes(data+skip*2,block,0,bytes);
    free(data);
    CMSampleTimingInfo timing = {CMTimeMake(1,48000),CMTimeMakeWithSeconds(t,1000000),kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    OSStatus rc = CMSampleBufferCreateReady(NULL,block,desc,count,1,&timing,0,NULL,&sample);
    CFRelease(block); CFRelease(desc);
    return (ClipSample){sample,t,(double)count/48000,pts,s->time_base.num,s->time_base.den,rc==0 ? 2 : -1};
}
static void cacheRawFrame(ClipMedia *m) {
    if (!m->cacheEnabled) return;
    AVFrame *f=m->frame;
    if (f->best_effort_timestamp==AV_NOPTS_VALUE) return;
    double t=f->best_effort_timestamp*av_q2d(m->format->streams[m->vi]->time_base)-m->info.origin;
    if (m->lastRaw>=0 && t>m->rawTime[m->lastRaw]) { m->rawDuration[m->lastRaw]=t-m->rawTime[m->lastRaw]; m->rawConfirmed[m->lastRaw]=1; }
    int slot=m->rawSlot++%12;
    av_frame_free(&m->rawCache[slot]); m->rawCache[slot]=av_frame_clone(f);
    m->rawTime[slot]=t; m->rawConfirmed[slot]=0; m->lastRaw=slot;
}
static int decodeFrame(ClipMedia *m) {
    av_frame_unref(m->frame);
    for (;;) {
        if (m->receiving) {
            AVCodecContext *ctx = m->receiving == 1 ? m->video : m->audio;
            int rc = avcodec_receive_frame(ctx, m->frame);
            if (rc == 0) {
                if (m->receiving==1) cacheRawFrame(m);
                return m->receiving;
            }
            if (rc != AVERROR(EAGAIN) && rc != AVERROR_EOF) return -1;
            m->receiving = 0;
        }
        if (m->eof) {
            if (!m->videoDrained) { m->videoDrained = 1; avcodec_send_packet(m->video,NULL); m->receiving=1; continue; }
            if (m->audio && !m->audioDrained) { m->audioDrained=1; avcodec_send_packet(m->audio,NULL); m->receiving=2; continue; }
            return 0;
        }
        int rc = av_read_frame(m->format,m->packet);
        if (rc == AVERROR_EOF) { m->eof=1; continue; }
        if (rc < 0) return -1;
        int kind = m->packet->stream_index == m->vi ? 1 : m->packet->stream_index == m->ai ? 2 : 0;
        AVCodecContext *ctx = kind == 1 ? m->video : kind == 2 ? m->audio : NULL;
        if (ctx) {
            rc = avcodec_send_packet(ctx,m->packet);
            if (rc < 0 && rc != AVERROR(EAGAIN)) { av_packet_unref(m->packet); return -1; }
            m->receiving=kind;
        }
        av_packet_unref(m->packet);
    }
}
ClipSample clip_next(ClipMedia *m) {
    for (;;) {
        int kind=decodeFrame(m);
        if (kind<=0) return (ClipSample){.kind=kind};
        ClipSample sample=kind==1 ? videoSample(m,m->frame) : audioSample(m,m->frame);
        cacheFrame(m,sample);
        if (sample.kind!=-2) return sample;
    }
}
ClipSample clip_frame_cancellable(ClipMedia *m, double time, ClipRequest *request, int generation) {
    ClipSample previous = {0};
    for (int i=0;i<12;i++) {
        ClipSample s=m->cache[i];
        if (!s.sample) continue;
        if (m->confirmed[i] && time>=s.time-0.0000001 && time<s.time+s.duration-0.0000001) { CFRetain(s.sample); return s; }
        if (fabs(s.time-m->lastDecoded)<0.0000001 && time>=s.time && time<s.time+0.25) previous=s;
    }
    for (int i=0;i<12;i++) {
        if (m->rawCache[i] && m->rawConfirmed[i] && time>=m->rawTime[i]-0.0000001 && time<m->rawTime[i]+m->rawDuration[i]-0.0000001) {
            ClipSample sample=videoSample(m,m->rawCache[i]); sample.duration=m->rawDuration[i]; return sample;
        }
    }
    if (previous.sample) CFRetain(previous.sample);
    else if (clip_seek(m,fmax(0,time)) < 0) return (ClipSample){.kind=-1};
    AVFrame *raw=av_frame_alloc();
    for (;;) {
        if (request && atomic_load(&request->generation)!=generation) { if (previous.sample) CFRelease(previous.sample); av_frame_free(&raw); return (ClipSample){.kind=-3}; }
        int kind=decodeFrame(m);
        if (kind<=0) {
            if (raw->buf[0]) { if (previous.sample) CFRelease(previous.sample); previous=videoSample(m,raw); cacheFrame(m,previous); }
            av_frame_free(&raw); return previous.kind==1 ? previous : (ClipSample){.kind=kind};
        }
        if (kind==2) continue;
        AVStream *stream=m->format->streams[m->vi];
        double t=m->frame->best_effort_timestamp*av_q2d(stream->time_base)-m->info.origin;
        if (t<=time+0.000001) { av_frame_unref(raw); av_frame_ref(raw,m->frame); continue; }
        ClipSample next=videoSample(m,m->frame);
        if (raw->buf[0]) { if (previous.sample) CFRelease(previous.sample); previous=videoSample(m,raw); cacheFrame(m,previous); }
        cacheFrame(m,next); av_frame_free(&raw);
        if (next.time > time + 0.000001) {
            if (previous.kind == 1) { previous.duration = next.time-previous.time; CFRelease(next.sample); return previous; }
            return next;
        }
        if (next.sample) CFRelease(next.sample);
    }
}
ClipSample clip_frame(ClipMedia *m, double time) { return clip_frame_cancellable(m,time,NULL,0); }
