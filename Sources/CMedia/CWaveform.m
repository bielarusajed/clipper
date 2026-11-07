#import "CMedia.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/samplefmt.h>
#include <math.h>

struct ClipWaveform {
    AVFormatContext *format;
    AVCodecContext *decoder;
    AVFrame *frame;
    AVPacket *packet;
    ClipRequest *request;
    int generation, stream, decoded;
    double origin, nextTime, position;
};
static int interrupted(void *opaque) {
    ClipWaveform *r=opaque;
    return !clip_request_current(r->request,r->generation);
}
void clip_waveform_close(ClipWaveform *r) {
    if (!r) return;
    av_frame_free(&r->frame); av_packet_free(&r->packet);
    avcodec_free_context(&r->decoder); avformat_close_input(&r->format); free(r);
}
ClipWaveform *clip_waveform_open(const char *path,int stream,double origin,
                                ClipRequest *request,int generation,char *error,int errorSize) {
    ClipWaveform *r=calloc(1,sizeof(*r));
    int rc=AVERROR(ENOMEM);
    if (!r) goto fail;
    r->request=request; r->generation=generation; r->stream=stream;
    r->origin=origin; r->nextTime=NAN;
    r->format=avformat_alloc_context();
    if (!r->format) goto fail;
    r->format->interrupt_callback=(AVIOInterruptCB){interrupted,r};
    if (interrupted(r)) { rc=AVERROR_EXIT; goto fail; }
    rc=avformat_open_input(&r->format,path,NULL,NULL);
    if (rc<0) goto fail;
    for (unsigned i=0;i<r->format->nb_streams;i++)
        if (i!=stream) r->format->streams[i]->discard=AVDISCARD_ALL;
    if (stream<0) { rc=AVERROR_STREAM_NOT_FOUND; goto fail; }
    if (stream>=r->format->nb_streams || !r->format->streams[stream]->codecpar->sample_rate ||
        !r->format->streams[stream]->codecpar->ch_layout.nb_channels) {
        rc=avformat_find_stream_info(r->format,NULL);
        if (rc<0) goto fail;
    }
    if (stream>=r->format->nb_streams || r->format->streams[stream]->codecpar->codec_type!=AVMEDIA_TYPE_AUDIO) {
        rc=AVERROR_STREAM_NOT_FOUND; goto fail;
    }
    for (unsigned i=0;i<r->format->nb_streams;i++)
        if (i!=stream) r->format->streams[i]->discard=AVDISCARD_ALL;
    AVCodecParameters *p=r->format->streams[stream]->codecpar;
    const AVCodec *codec=avcodec_find_decoder(p->codec_id);
    if (!codec) { rc=AVERROR_DECODER_NOT_FOUND; goto fail; }
    r->decoder=avcodec_alloc_context3(codec);
    if (!r->decoder) { rc=AVERROR(ENOMEM); goto fail; }
    rc=avcodec_parameters_to_context(r->decoder,p);
    if (rc<0) goto fail;
    r->decoder->pkt_timebase=r->format->streams[stream]->time_base;
    r->decoder->thread_count=1;
    rc=avcodec_open2(r->decoder,codec,NULL);
    if (rc<0) goto fail;
    r->frame=av_frame_alloc(); r->packet=av_packet_alloc();
    if (!r->frame || !r->packet) { rc=AVERROR(ENOMEM); goto fail; }
    return r;
fail:
    av_strerror(rc,error,errorSize); clip_waveform_close(r); return NULL;
}
static double magnitude(const uint8_t *data,int index,enum AVSampleFormat format) {
    switch (format) {
        case AV_SAMPLE_FMT_U8: return abs(((const uint8_t *)data)[index]-128)/128.0;
        case AV_SAMPLE_FMT_S16: return fabs(((const int16_t *)data)[index]/32768.0);
        case AV_SAMPLE_FMT_S32: return fabs(((const int32_t *)data)[index]/2147483648.0);
        case AV_SAMPLE_FMT_S64: return fabs(((const int64_t *)data)[index]/9223372036854775808.0);
        case AV_SAMPLE_FMT_FLT: return fabs(((const float *)data)[index]);
        case AV_SAMPLE_FMT_DBL: return fabs(((const double *)data)[index]);
        default: return 0;
    }
}
static int accumulate(ClipWaveform *r,float *peaks,int count,double width) {
    AVFrame *f=r->frame;
    int rate=f->sample_rate, channels=f->ch_layout.nb_channels;
    enum AVSampleFormat packed=av_get_packed_sample_fmt(f->format);
    if (rate<=0 || channels<=0 || av_get_bytes_per_sample(packed)<=0) return AVERROR_INVALIDDATA;
    int64_t pts=f->best_effort_timestamp;
    if (pts==AV_NOPTS_VALUE) pts=f->pts;
    double t=pts==AV_NOPTS_VALUE ? r->nextTime : pts*av_q2d(r->format->streams[r->stream]->time_base)-r->origin;
    if (!isfinite(t)) return AVERROR_INVALIDDATA;
    r->nextTime=t+(double)f->nb_samples/rate;
    r->position=fmax(r->position,r->nextTime); r->decoded++;
    int planar=av_sample_fmt_is_planar(f->format);
    // Work a bin at a time, without resampling or retaining PCM across frames.
    int sample=(int)fmin(f->nb_samples,fmax(0,ceil(-t*rate)));
    while (sample<f->nb_samples) {
        if (interrupted(r)) return AVERROR_EXIT;
        double time=t+(double)sample/rate;
        if (time>=count*width) break;
        int bin=(int)floor(fmax(0,time)/width);
        // Rounded division can reach count even when time<count*width.
        if (bin>=count) bin=count-1;
        int end=(int)fmin(f->nb_samples,fmax(sample+1,ceil(((bin+1)*width-t)*rate-1e-7)));
        float peak=peaks[bin];
        for (int n=sample;n<end;n++) for (int ch=0;ch<channels;ch++) {
            double value=magnitude(f->extended_data[planar ? ch : 0],planar ? n : n*channels+ch,packed);
            if (isfinite(value)) peak=fmaxf(peak,(float)fmin(1,value));
        }
        peaks[bin]=peak; sample=end;
    }
    return 0;
}
static int receive(ClipWaveform *r,float *peaks,int count,double width) {
    int rc;
    while ((rc=avcodec_receive_frame(r->decoder,r->frame))>=0) {
        rc=accumulate(r,peaks,count,width); av_frame_unref(r->frame);
        if (rc<0) return rc;
    }
    return rc==AVERROR(EAGAIN) || rc==AVERROR_EOF || rc==AVERROR_INVALIDDATA ? 0 : rc;
}
int clip_waveform_step(ClipWaveform *r,float *peaks,int count,double width,
                       double *position,char *error,int errorSize) {
    int rc=0;
    if (!peaks || count<=0 || !isfinite(width) || width<=0) { rc=AVERROR(EINVAL); goto fail; }
    for (int n=0;n<64;n++) {
        if (interrupted(r)) { rc=AVERROR_EXIT; goto fail; }
        rc=av_read_frame(r->format,r->packet);
        if (rc==AVERROR_EOF) {
            rc=avcodec_send_packet(r->decoder,NULL);
            if (rc>=0) rc=receive(r,peaks,count,width);
            if (rc<0) goto fail;
            if (!r->decoded) { rc=AVERROR_INVALIDDATA; goto fail; }
            *position=r->position; return 0;
        }
        if (rc<0) goto fail;
        if (r->packet->stream_index==r->stream) {
            rc=avcodec_send_packet(r->decoder,r->packet);
            av_packet_unref(r->packet);
            if (rc==AVERROR_INVALIDDATA) continue;
            if (rc<0) goto fail;
            rc=receive(r,peaks,count,width);
            if (rc<0) goto fail;
        } else av_packet_unref(r->packet);
    }
    *position=r->position; return 1;
fail:
    av_strerror(rc,error,errorSize); return rc;
}
