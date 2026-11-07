#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FFMPEG="${FIXTURE_FFMPEG:-/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg}"
mkdir -p .build/fixtures
# Test-only software encoders. Neither this FFmpeg nor these fixtures are bundled.
"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i 'color=s=160x90:r=24:d=5' \
  -f lavfi -i 'aevalsrc=if(between(t\,1\,1.02)+between(t\,3\,3.02)\,0.8\,0)|if(between(t\,1\,1.02)+between(t\,3\,3.02)\,-0.8\,0):s=48000:d=4' \
  -f lavfi -i 'aevalsrc=if(between(t\,2\,2.02)\,0.6\,0):s=44100:d=4' \
  -filter_complex '[0:v]select=not(mod(n\,2))+not(mod(n\,5)),setpts=PTS+7/TB[v];[1:a]asetpts=PTS+7.35/TB[a];[2:a]asetpts=PTS+7.1/TB[b]' \
  -map '[v]' -map '[a]' -map '[b]' -fps_mode vfr -c:v mpeg4 -bf 0 -c:a flac .build/fixtures/waveform-offset.mkv
"$FFMPEG" -hide_banner -loglevel error -y -i .build/fixtures/waveform-offset.mkv -map 0:v -c:v copy -an .build/fixtures/waveform-silent.mkv
# Two short PCM regions separated by a 100,000-second presentation-time gap.
# Exercises the real long-duration allocator and sparse timestamps without hours of PCM.
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'aevalsrc=0.7:s=48000:d=0.2' \
  -af 'asetpts=PTS+if(gte(T\,0.1)\,100000/TB\,0)' -c:a flac .build/fixtures/waveform-long.mka
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'color=s=160x90:r=24:d=2' \
  -f lavfi -i 'aevalsrc=if(between(t\,0.5\,0.52)\,0.8\,0):s=48000:d=2' \
  -c:v mpeg4 -bf 0 -c:a aac .build/fixtures/waveform-aac.mp4
"$FFMPEG" -hide_banner -loglevel error -y -i .build/fixtures/waveform-aac.mp4 \
  -c:v copy -c:a libopus .build/fixtures/waveform-opus.mkv
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi \
  -i 'aevalsrc=if(lt(mod(t\,30)\,0.01)\,0.5\,0):s=8000:d=180' \
  -c:a flac .build/fixtures/waveform-moderate.mka
