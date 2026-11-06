# Clipper v1

Confirmed with the user on 2026-11-06 after a product interview and three Claude architecture consultations.

## Product

Standalone native macOS app for Apple Silicon. Drag a file, choose Open, or use Finder's Open With. Inputs include screen recordings, MP4/MOV, YouTube WebM, MKV shows, and occasional AVI. One selected clip per export. Keep the source open for the next clip.

The viewer supports playback, exact decoded-frame seeking, previous/next frame, I/O to mark inclusive start/end frames, and editable millisecond timestamps. A zoomable filmstrip timeline has draggable selection handles. Frame selection follows decoded timestamps, not nominal frame rate.

Framing presets are Original, 16:9, 9:16, 1:1, 4:5, and a custom numeric ratio. Reposition and resize the crop over the video. Preserve resolution by default; offer 4K, 1440p, 1080p, 720p, and 480p long-edge limits without upscaling.

Export MP4 through hardware H.264 or HEVC only, without software encoder fallback. SDR defaults to H.264 and quality 65. One quality slider, no target file size. HDR defaults to HEVC Main10 with explicit SDR tone-mapping available. Pick an audio track or mute; export AAC stereo. Omit subtitles. Preserve source frame timing.

Render a five-second encoded preview beginning at the playhead and bounded to the selected clip. Switch between original and output. Invalidate it when the edit changes.

One-click export beside the source with a unique filename; Save As offers another destination. Never overwrite source or existing files. Show progress, cancellation and errors; reveal completed exports in Finder.

## Architecture agreement

SwiftUI and AppKit shell, in-process libav decoding, native AVSampleBufferDisplayLayer and AVSampleBufferAudioRenderer driven by one AVSampleBufferRenderSynchronizer. One demuxer and decoder determine source frame identity for all input formats. No whole-file proxy or temporary video conversion is needed to edit WebM/MKV. Software decoding is allowed for codecs without hardware decode support; video encoding is hardware-only.

Export uses a bundled FFmpeg helper, with source timestamps, decode-and-trim, crop/scale and VideoToolbox encoders with allow_sw=0. AVPlayer displays the finished MP4 quality preview. FFmpeg is built from official source without GPL or nonfree components. Bundle its dylibs, dav1d and zimg. Ship corresponding sources and notices with distribution artifacts.

Use Xcode explicitly through DEVELOPER_DIR. Ship an ad-hoc signed self-contained arm64 app first. Developer ID signing and notarization are deferred by user agreement. Recipients may need to approve first launch through macOS security settings.

## Verification

Build and package locally. Generate synthetic media with known frame identity and timestamps. Verify decoded seeks and exported first/last frames, frame counts, VFR timing, nonzero start timestamps, audio alignment, crop geometry, rotation, HDR metadata and hardware encoding. Test cancellation and bundle dependencies. Obtain Claude standards and spec reviews, fix findings and resolve disagreements before final delivery.
