#import <Foundation/Foundation.h>
#import "CMedia.h"
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
int main(int argc,char **argv) { @autoreleasepool {
    if (argc < 2) return 2;
    char error[512]={0}; double begin=now();
    ClipMedia *m=clip_open(argv[1],-1,error,512);
    if (!m) { fprintf(stderr,"%s\n",error); return 2; }
    printf("open_ms=%.1f\n",(now()-begin)*1000); fflush(stdout);
    clip_enable_cache(m);
    double target=argc > 2 ? atof(argv[2]) : 493.5;
    double maximum=0;
    for (int i=0;i<3;i++) {
        begin=now(); ClipSample sample=clip_frame(m,target+i*0.5);
        double elapsed=now()-begin; if (elapsed>maximum) maximum=elapsed;
        printf("seek_%.3f_ms=%.1f frame=%.6f\n",target+i*0.5,elapsed*1000,sample.time); fflush(stdout);
        if (sample.sample) CFRelease(sample.sample);
    }
    clip_seek(m,target);
    int frames=0; double last=0; begin=now();
    while (frames<390) {
        ClipSample sample=clip_next(m);
        if (sample.sample) CFRelease(sample.sample);
        if (sample.kind<=0) break;
        if (sample.kind==1 && sample.time>=target) { frames++; last=sample.time; }
    }
    double elapsed=now()-begin;
    printf("decode_frames=%d elapsed_s=%.3f fps=%.2f end=%.6f\n",frames,elapsed,frames/elapsed,last);
    ClipSample point=clip_frame(m,target); if (point.sample) CFRelease(point.sample);
    begin=now();
    for(int i=0;i<20;i++) { point=clip_frame(m,point.time+point.duration+0.000002); if(point.sample) CFRelease(point.sample); }
    double step=(now()-begin)/20;
    printf("forward_step_mean_ms=%.2f\n",step*1000);
    clip_close(m);
    if (maximum>0.6 || frames/elapsed<60) { puts("FAIL: seek >600ms or playback decode <60fps"); return 1; }
    puts("PASS"); return 0;
}}
