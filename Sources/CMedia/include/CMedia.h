#pragma once
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreGraphics/CoreGraphics.h>


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
    int colorSpace;
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
// Prepare cached A/V for playback if a complete current decode segment covers start.
int clip_resume(ClipMedia *media, double start);
ClipSample clip_next(ClipMedia *media);
ClipSample clip_next_cancellable(ClipMedia *media, ClipRequest *request, int generation);
// Seeks and decodes the actual frame whose display interval contains time.
ClipSample clip_frame(ClipMedia *media, double time);
ClipSample clip_frame_cancellable(ClipMedia *media, double time, ClipRequest *request, int generation);
ClipSample clip_thumbnail(ClipMedia *media, double time, ClipRequest *request, int generation);

// Subtitle catalog and font attachments. Catalog owns its demuxer; never shares playback state.
typedef struct ClipSubtitleCatalog ClipSubtitleCatalog;
ClipSubtitleCatalog *clip_subtitle_catalog(const char *path, const char *fontsDirectory);
void clip_subtitle_catalog_free(ClipSubtitleCatalog *catalog);
int clip_subtitle_count(ClipSubtitleCatalog *catalog);
int clip_subtitle_stream(ClipSubtitleCatalog *catalog, int index);
const char *clip_subtitle_label(ClipSubtitleCatalog *catalog, int index);
int clip_subtitle_styled(ClipSubtitleCatalog *catalog, int index);
int clip_subtitle_default(ClipSubtitleCatalog *catalog, int index);
int clip_subtitle_unsupported(ClipSubtitleCatalog *catalog);

typedef struct ClipSubtitles ClipSubtitles;
ClipSubtitles *clip_subtitles_open(const char *path, const char *fontsDirectory);
void clip_subtitles_free(ClipSubtitles *subtitles);
int clip_subtitles_events(ClipSubtitles *subtitles);
// Returns a retained premultiplied RGBA image of the visible bounding box, or NULL.
// All calls for a renderer must run on the same serial queue.
CGImageRef clip_subtitles_render(ClipSubtitles *subtitles, int64_t milliseconds,
                                int width, int height, int *x, int *y, int *changed);
