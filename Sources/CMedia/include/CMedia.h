#pragma once
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

typedef struct ClipMedia ClipMedia;
typedef struct ClipRequest ClipRequest;
ClipRequest *clip_request_create(void);
void clip_request_free(ClipRequest *request);
void clip_request_set(ClipRequest *request, int generation);
typedef struct {
    double duration;
    double origin;
    int width, height;
    double rotation, pixelAspect, fps;
    int hdr;
    int audioCount;
    char codec[64];
} ClipInfo;
typedef struct {
    CMSampleBufferRef sample; // Caller owns this reference.
    double time, duration;
    int64_t pts;
    int timeBaseNum, timeBaseDen;
    int kind; // 1 video, 2 audio, 0 EOF, -1 failure
} ClipSample;

ClipMedia *clip_open(const char *path, int audioTrack, char *error, int errorSize);
void clip_close(ClipMedia *media);
ClipInfo clip_info(ClipMedia *media);
const char *clip_audio_label(ClipMedia *media, int track);
int clip_audio_stream(ClipMedia *media, int track);
int clip_seek(ClipMedia *media, double time);
void clip_enable_cache(ClipMedia *media);
ClipSample clip_next(ClipMedia *media);
ClipSample clip_next_cancellable(ClipMedia *media, ClipRequest *request, int generation);
// Seeks and decodes the actual frame whose display interval contains time.
ClipSample clip_frame(ClipMedia *media, double time);
ClipSample clip_frame_cancellable(ClipMedia *media, double time, ClipRequest *request, int generation);
ClipSample clip_thumbnail(ClipMedia *media, double time, ClipRequest *request, int generation);
