#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
F=.build/fixtures/subtitles
mkdir -p "$F"
FF=.build/media/bin/ffmpeg
python3 - <<'RAW'
from pathlib import Path
p=Path('.build/fixtures/subtitles/black.yuv')
frame=bytes([16])*(640*360)+bytes([128])*(640*360//2)
with p.open('wb') as f:
    for _ in range(8*24): f.write(frame)
RAW
"$FF" -v error -y -f rawvideo -pixel_format yuv420p -video_size 640x360 -framerate 24 -i "$F/black.yuv" -c:v h264_videotoolbox -allow_sw 0 -pix_fmt nv12 "$F/black.mp4"
rm "$F/black.yuv"
cat > "$F/dialogue.srt" <<'SRT'
1
00:00:02,000 --> 00:00:04,000
Subtitle parity

2
00:01:00,000 --> 00:01:01,000
Late cue
SRT
cat > "$F/dialogue.vtt" <<'VTT'
WEBVTT

00:00:02.000 --> 00:00:04.000
<i>WebVTT cue</i>
VTT
cat > "$F/styled.ass" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
YCbCr Matrix: None
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica Neue,32,&H0000FFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,7,10,10,10,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,{\pos(100,80)}Authored position
ASS
"$FF" -v error -y -copyts -i "$F/black.mp4" -i "$F/dialogue.srt" -i "$F/styled.ass" -map 0:v -map 1:s -map 2:s -c:v copy -c:s ass -metadata:s:s:0 language=eng -metadata:s:s:1 language=pol -disposition:s:0 default "$F/two-tracks.mkv"
"$FF" -v error -y -copyts -i "$F/two-tracks.mkv" -map 0 -c copy -output_ts_offset 10 "$F/offset-tracks.mkv"
# Legacy SSA is a real v4 script.
sed -e 's/v4.00+/v4.00/' -e 's/V4+ Styles/V4 Styles/' -e 's/Layer, Start/Marked, Start/' -e 's/Dialogue: 0,/Dialogue: Marked=0,/' "$F/styled.ass" > "$F/styled.ssa"

"$FF" -v error -y -i "$F/two-tracks.mkv" -map 0 -c copy -attach /System/Library/Fonts/Supplemental/Arial.ttf -metadata:s:t:0 mimetype=application/x-truetype-font "$F/attached-font.mkv"
"$FF" -v error -y -i "$F/two-tracks.mkv" -map 0:v -map 0:s:0 -c copy "$F/one-track.mkv"

"$FF" -v error -y -i "$F/black.mp4" -vf scale=1280:720 -c:v h264_videotoolbox -allow_sw 0 -colorspace unspecified "$F/hd-untagged.mp4"
