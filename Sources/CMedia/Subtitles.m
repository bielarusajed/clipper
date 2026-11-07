#import "CMedia.h"
#include <libavformat/avformat.h>
#include <ass/ass.h>
#include <stdio.h>

struct ClipSubtitleCatalog { int count, unsupported; int streams[64], styled[64], defaults[64]; char labels[64][192]; };
ClipSubtitleCatalog *clip_subtitle_catalog(const char *path,const char *fonts) {
    AVFormatContext *f=NULL;
    if (avformat_open_input(&f,path,NULL,NULL)<0) return NULL;
    if (avformat_find_stream_info(f,NULL)<0) { avformat_close_input(&f); return NULL; }
    ClipSubtitleCatalog *c=calloc(1,sizeof(*c));
    size_t fontBytes=0;
    for (unsigned i=0;i<f->nb_streams;i++) {
        AVStream *s=f->streams[i]; AVCodecParameters *p=s->codecpar;
        if (p->codec_type==AVMEDIA_TYPE_SUBTITLE) {
            int styled=p->codec_id==AV_CODEC_ID_ASS || p->codec_id==AV_CODEC_ID_SSA;
            int eligible=styled || p->codec_id==AV_CODEC_ID_SUBRIP || p->codec_id==AV_CODEC_ID_WEBVTT || p->codec_id==AV_CODEC_ID_MOV_TEXT;
            if (!eligible || c->count==64) { c->unsupported++; continue; }
            int n=c->count++; c->streams[n]=i; c->styled[n]=styled; c->defaults[n]=(s->disposition&AV_DISPOSITION_DEFAULT)!=0;
            AVDictionaryEntry *lang=av_dict_get(s->metadata,"language",NULL,0), *title=av_dict_get(s->metadata,"title",NULL,0);
            snprintf(c->labels[n],192,"%d. %s%s%s (%s)",n+1,lang?lang->value:"Subtitles",title?" / ":"",title?title->value:"",avcodec_get_name(p->codec_id));
        } else if (fonts && p->codec_type==AVMEDIA_TYPE_ATTACHMENT && p->extradata_size>0) {
            AVDictionaryEntry *mime=av_dict_get(s->metadata,"mimetype",NULL,0);
            const char *type=mime?mime->value:"";
            int isFont=p->codec_id==AV_CODEC_ID_TTF || p->codec_id==AV_CODEC_ID_OTF ||
                !strcmp(type,"application/x-truetype-font") || !strcmp(type,"application/vnd.ms-opentype") ||
                !strcmp(type,"application/x-font-ttf") || !strcmp(type,"application/x-font") ||
                !strcmp(type,"application/font-sfnt") || !strcmp(type,"font/ttf") || !strcmp(type,"font/otf") || !strcmp(type,"font/collection");
            if (!isFont || fontBytes+(size_t)p->extradata_size>64*1024*1024) continue;
            char name[4096]; snprintf(name,sizeof(name),"%s/font-%u.ttf",fonts,i);
            FILE *out=fopen(name,"wb"); if (out) { fwrite(p->extradata,1,p->extradata_size,out); fclose(out); fontBytes+=p->extradata_size; }
        }
    }
    avformat_close_input(&f); return c;
}
void clip_subtitle_catalog_free(ClipSubtitleCatalog *c) { free(c); }
int clip_subtitle_count(ClipSubtitleCatalog *c) { return c->count; }
int clip_subtitle_stream(ClipSubtitleCatalog *c,int i) { return c->streams[i]; }
const char *clip_subtitle_label(ClipSubtitleCatalog *c,int i) { return c->labels[i]; }
int clip_subtitle_styled(ClipSubtitleCatalog *c,int i) { return c->styled[i]; }
int clip_subtitle_default(ClipSubtitleCatalog *c,int i) { return c->defaults[i]; }
int clip_subtitle_unsupported(ClipSubtitleCatalog *c) { return c->unsupported; }
struct ClipSubtitles { ASS_Library *library; ASS_Renderer *renderer; ASS_Track *track; };
static void quiet(int level,const char *fmt,va_list args,void *data) {}
ClipSubtitles *clip_subtitles_open(const char *path,const char *fonts) {
    ClipSubtitles *s=calloc(1,sizeof(*s));
    s->library=ass_library_init(); if (!s->library) goto fail;
    ass_set_message_cb(s->library,quiet,NULL);
    ass_set_fonts_dir(s->library,fonts); ass_set_extract_fonts(s->library,1);
    s->renderer=ass_renderer_init(s->library); if (!s->renderer) goto fail;
    ass_set_fonts(s->renderer,NULL,NULL,ASS_FONTPROVIDER_CORETEXT,NULL,1);
    ass_set_shaper(s->renderer,ASS_SHAPING_COMPLEX);
    s->track=ass_read_file(s->library,(char *)path,"UTF-8"); if (!s->track) goto fail;
    return s;
fail: clip_subtitles_free(s); return NULL;
}
void clip_subtitles_free(ClipSubtitles *s) {
    if (!s) return; if (s->track) ass_free_track(s->track);
    if (s->renderer) ass_renderer_done(s->renderer); if (s->library) ass_library_done(s->library); free(s);
}
int clip_subtitles_events(ClipSubtitles *s) { return s->track->n_events; }
static void releasePixels(void *info,const void *data,size_t size) { free((void *)data); }
CGImageRef clip_subtitles_render(ClipSubtitles *s,int64_t ms,int width,int height,int *x,int *y,int *changed) {
    if (!s || width<1 || height<1 || width>16384 || height>16384) return NULL;
    ass_set_frame_size(s->renderer,width,height); ass_set_storage_size(s->renderer,width,height);
    ASS_Image *images=ass_render_frame(s->renderer,s->track,ms,changed);
    if (!*changed) return NULL;
    int x0=width,y0=height,x1=0,y1=0;
    for (ASS_Image *i=images;i;i=i->next) {
        if (!i->w || !i->h) continue;
        x0=MIN(x0,MAX(0,i->dst_x)); y0=MIN(y0,MAX(0,i->dst_y));
        x1=MAX(x1,MIN(width,i->dst_x+i->w)); y1=MAX(y1,MIN(height,i->dst_y+i->h));
    }
    if (x1<=x0 || y1<=y0) return NULL;
    int w=x1-x0,h=y1-y0; size_t stride=w*4;
    uint8_t *pixels=calloc(h,stride); if (!pixels) return NULL;
    for (ASS_Image *i=images;i;i=i->next) {
        unsigned r=i->color>>24,g=(i->color>>16)&255,b=(i->color>>8)&255,opacity=255-(i->color&255);
        for (int py=MAX(y0,i->dst_y);py<MIN(y1,i->dst_y+i->h);py++) {
            for (int px=MAX(x0,i->dst_x);px<MIN(x1,i->dst_x+i->w);px++) {
                unsigned a=(i->bitmap[(py-i->dst_y)*i->stride+px-i->dst_x]*opacity+127)/255;
                uint8_t *p=pixels+(py-y0)*stride+(px-x0)*4;
                p[0]=(r*a+p[0]*(255-a)+127)/255; p[1]=(g*a+p[1]*(255-a)+127)/255;
                p[2]=(b*a+p[2]*(255-a)+127)/255; p[3]=a+(p[3]*(255-a)+127)/255;
            }
        }
    }
    CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,pixels,h*stride,releasePixels);
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image=CGImageCreate(w,h,8,32,stride,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big,provider,NULL,false,kCGRenderingIntentDefault);
    CGColorSpaceRelease(space); CGDataProviderRelease(provider); *x=x0; *y=y0; return image;
}
