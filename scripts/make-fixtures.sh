#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FFMPEG="${FIXTURE_FFMPEG:-/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg}"
mkdir -p .build/fixtures
# The test-only tool may contain GPL codecs. It is never bundled in Clipper.
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'nullsrc=s=160x90:r=24:d=6,geq=lum=16+N*1.4:cb=128:cr=128' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=6' -c:v libx264 -g 48 -bf 3 -crf 10 -c:a aac -shortest .build/fixtures/cfr.mp4
"$FFMPEG" -hide_banner -loglevel error -y -i .build/fixtures/cfr.mp4 -vf "select='not(mod(n,2))+not(mod(n,5))'" -fps_mode vfr -c:v libx264 -g 36 -crf 10 -c:a copy .build/fixtures/vfr.mkv
"$FFMPEG" -hide_banner -loglevel error -y -i .build/fixtures/cfr.mp4 -c:v libvpx-vp9 -b:v 0 -crf 15 -c:a libopus .build/fixtures/vp9.webm
"$FFMPEG" -hide_banner -loglevel error -y -i .build/fixtures/cfr.mp4 -c:v mpeg4 -q:v 2 -c:a mp3 .build/fixtures/legacy.avi
"$FFMPEG" -hide_banner -loglevel error -y -i .build/fixtures/cfr.mp4 -c copy -output_ts_offset 10 .build/fixtures/offset.mkv
"$FFMPEG" -hide_banner -loglevel error -y -display_rotation 90 -i .build/fixtures/cfr.mp4 -c copy .build/fixtures/rotated.mp4
"$FFMPEG" -hide_banner -loglevel error -y -i .build/fixtures/cfr.mp4 -vf 'format=yuv420p10le' -c:v libaom-av1 -cpu-used 8 -crf 20 -c:a libopus .build/fixtures/av1.webm
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=s=320x180:r=24:d=2' -vf 'format=yuv420p10le' -c:v libx265 -x265-params 'colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:log-level=error' -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc .build/fixtures/hdr.mp4
echo 'Fixtures ready'
