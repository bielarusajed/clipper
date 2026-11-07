<img src="assets/icon.svg" width="64" height="64" alt="">

# Clipper

A native Mac app for cutting a precise clip without setting up a video editor. Drop a video, mark its start and end, adjust the framing if needed, and export an MP4.

## Use

Open `dist/Clipper.app`. The app includes its media engine and needs no Homebrew or terminal. Local editing works offline. URL imports download their tools automatically on first use. The build targets Apple Silicon Macs running macOS 14 or newer. This first build is ad-hoc signed. Shared copies may need approval in System Settings → Privacy & Security on first launch. Developer ID signing and notarization are deferred.

- Open MP4, MOV, MKV, WebM, and AVI through the file picker, drag and drop, or Finder's Open With.
- Start in a compact window. Opening a video restores the editor width and fits its height to the video and controls. The current screen's available area, excluding the menu bar and Dock, limits the window height. Tall videos narrow the window to fit; closing a video returns to the compact starter.
- Paste a URL into the main window with Cmd-V or Edit → Paste to open the compact importer and start loading formats in the background. Download and the format button reuse that lookup; opening the table while it is loading shows its current status. Copied Finder video files, local file URLs and readable video paths open directly. Pasting into editable text fields keeps the normal text-editing behavior.
- Choose Import URL in the empty state or File → Import URL (Shift-Cmd-O). Paste a URL and press Download to import with `bv+ba/b`. Cmd-Enter or the split button's format icon opens a table with format IDs, containers, resolutions, frame rates, sizes and codecs. Select one video and an audio stream, or No audio. Combined formats keep their included audio unless No audio is selected. Enter downloads the current selections in the extended view. Background prefetch leaves both button segments available. Opening formats or requesting Download reveals progress inside the button and changes the format icon to cancel. The title-bar close button cancels work and closes the import window. Audio-only imports are not supported.
- To fetch a small window from a long URL video, enable Import a rough time range and enter original-video start/end times, such as `08:00` and `08:30`. Clipper asks for five seconds of padding on each side and may include an earlier keyframe. After import, the timeline and editable timestamps show original-video time; precise local playback/export uses the measured offset. Range mode requires a finite end even when the site's duration is unavailable. A timestamp link may offer an opt-in 30-second suggestion; full import remains the default. Unsupported or unverifiable ranges offer Import full video and never silently start a full download. Transfer savings depend on the server, seek index and format. Ranged imports omit subtitles/data, use millisecond Matroska timestamps, and disable yt-dlp's automatic fixups, including rare stretched-aspect corrections. Long keyframe gaps over 60 seconds, DRM, live streams, and some encrypted HLS formats are unsupported.
- Downloaded sources are disposable temporary files, removed when the video closes, is replaced, or Clipper quits. Launching Clipper also removes abandoned import workspaces after a crash, preserving those owned by a running instance. Export Clip opens a Save dialog for imported sources in the last confirmed Save As folder, falling back to Downloads. Exported clips survive source cleanup. Local source files keep their existing export behavior. Playlists, live streams, DRM, and authenticated browser-cookie imports are not supported. Supported sites depend on the current [yt-dlp release](https://github.com/yt-dlp/yt-dlp).
- Clipper manages official standalone yt-dlp and Deno releases in `~/Library/Application Support/Clipper/Tools`, independently of app releases. It checks for stable updates once per day when importing. A failed format lookup can check sooner, at most once per hour, and retries once with the refreshed tools. It verifies SHA-256, Mac architecture, and reported version before switching, and retains the previous version. A failed update uses the installed tool; if the import also fails, its error includes the update problem. First use requires internet access to GitHub. System yt-dlp, Python, Deno, and FFmpeg installations are not used. Downloads trust GitHub over HTTPS and GitHub's published checksums; Clipper does not independently verify upstream GPG signatures. The [Deno runtime is required by current YouTube extraction](https://github.com/yt-dlp/yt-dlp/wiki/EJS). Proxy environment variables are passed through; automatic macOS proxy configuration is not translated into yt-dlp settings.
- Scrub the filmstrip, drag the amber selection edges, and zoom down to individual frame boundaries.
- Zoom with Cmd+plus/Cmd+minus or pinch the timeline. Cmd+0 fits the whole video. The horizontal scrollbar stays visible while the timeline can scroll.
- Turn on the waveform button beside the timeline zoom controls, or View → Show Audio Waveform, to see the selected source audio track below the filmstrip. It starts off and is hidden for videos without audio. Peaks generate in the background while idle, with progress until ready. Playback, seeking and export pause generation. Switching tracks refreshes the waveform; two completed tracks are cached until the source closes. Muting export audio dims the waveform. Peak resolution is about 5 ms, coarser for sources longer than 83 minutes to keep memory bounded.
- Use Left/Right to step frames, Space to play/pause, I for the start, and O for the last included frame. Editable timestamps accept seconds or `hh:mm:ss.sss`.
- Toggle Loop Selection with the repeat button or Cmd-L, then press Space. Original prepares the next pass in a second decoder and repeats the selection on a continuous clock; very short selections can replay from a bounded frame cache. A "Rewind gap" indicator appears if preparation cannot keep up. Compare and Output repeat the available encoded sample using their existing seek path. Shift-Cmd-L or the cut-audition button plays the last second before the out point once and holds the last included frame. Short selections play in full. Audition uses Original when the encoded sample does not reach the cut. Markers stay unchanged. Pausing, seeking, stepping, moving a marker, switching modes, importing, or closing interrupts the current run. Mute, crop, and codec changes keep Original playing; changes that invalidate an encoded preview return to paused Original. Loop stays enabled until toggled off or the source is closed or replaced.
- Crop to Original, 16:9, 9:16, 1:1, 4:5, or a custom ratio. Drag the crop and its lower-right resize handle.
- Keep original resolution or downscale. Presets limit the longest edge and never enlarge the crop.
- Choose H.264 or H.265 and a quality setting. Video export uses VideoToolbox hardware encoding only. Unsupported encoder sizes produce an error rather than falling back to software.
- Codec and quality choices are remembered between videos and app launches. HDR temporarily requires H.265 without changing the preferred SDR codec. Convert to SDR restores that preference. Save As and imported-source save dialogs start in the last confirmed Save As folder, or Downloads if none is saved or the folder is unavailable. If Downloads is also unavailable, the dialog starts in your home folder. Trim, crop, resolution and audio choices reset with each video.
- HDR selects HEVC Main10. Convert to SDR explicitly for SDR sharing. Exclude audio with the switch, or choose a track when the source has several. Sources without audio hide the audio section. Audio exports as stereo AAC. Subtitles are off by default. Enable Subtitles to burn a container text track or an external SRT, WebVTT, ASS or SSA file into the video. The textformat button opens the anchored style popover. ASS/SSA keeps authored layout and styles unless Override authored style is enabled. Common styling uses output coordinates; authored styling uses the source frame and can be cut off by a crop. HDR burn-in requires Convert to SDR. External subtitle cues on a URL range import use original-video time when its mapping is verified, or local section time otherwise.
- Preview 5 Seconds renders a sample beginning at the playhead, bounded to the selection. Switch between original and output. Editing invalidates the sample.
- Floating glass panels hold the left settings and the timeline over one shared window material. The video fills the timeline column width when its aspect ratio allows, and the preview selector aligns with the top of the inspector. The app follows system light/dark appearance. Native glass is used on macOS 26 or newer, with a material fallback on earlier versions.
- Preview/export stay pinned below the left settings. Close the source with its × button to return to the Open Video empty state.
- After rendering a preview, choose Compare and drag the wipe to inspect the original crop beside the encoded output. Forward/backward steps align both halves. The episode overview pans the zoomed timeline without changing the clip.
- Export Clip writes a unique filename beside the source. Its right-hand folder button opens Save As directly and honors macOS's Replace confirmation for an existing output. The source video is protected. Replacement happens only after rendering succeeds; cancelling or a failed render leaves the previous output intact.
- After export, drag the file icon or filename into an app that accepts files, or use Copy and paste it there. Finder drops copy the clip. Show in Finder remains available. Moved or removed exports disable these actions until the file returns or another export succeeds. Save As rejects Clipper's disposable import folders.

## Build

Install Xcode and complete its first-run setup. Run:

```sh
bash scripts/build-app.sh
```

On the first build, the scripts download and build FFmpeg 8.0.1, dav1d 1.5.4, zimg 3.0.6, libass 0.17.3, FreeType 2.13.3, HarfBuzz 10.4.0 and FriBidi 1.0.16. Python 3, a C/C++ compiler and make are build-time requirements. Meson and Ninja are installed into a project-local virtual environment. No Homebrew library is required by the finished app. Build output and downloaded sources stay in `.build/`; the app is in `dist/`.

```sh
bash scripts/make-fixtures.sh   # Uses a separate test-only FFmpeg with software encoders.
bash scripts/test.sh
bash scripts/benchmark.sh /path/to/video.webm 493.5
```

The tests exercise real decoding, cached frame steps, VFR selection, hardware H.264/HEVC output, frame identity and count, crop geometry, rotation, HDR and SDR conversion. VideoToolbox and IOSurface access are required. Set `CLIPPER_SAMPLE` to a long 4K source to include the sample export test.

## Media engine and distribution

SwiftUI/AppKit controls sit above libav demux/decode and Apple's sample-buffer video and audio renderers. The decoded presentation timestamps determine selection boundaries. No proxy conversion is needed. Export uses the same FFmpeg build and source timestamps, then re-encodes with the hardware encoder. The original file is never modified.

The FFmpeg build excludes GPL and nonfree components. Networking uses macOS SecureTransport; a distributed patch enables certificate verification by default for HTTPS inputs, redirects and media segments. Remote range inputs use a protocol whitelist and a 30-second I/O timeout. Shared libraries, licenses and credits are included in the bundle. Run `bash scripts/package-release.sh` to create the app ZIP and a matching source ZIP with all dependency sources, exact build recipes and package receipts. Distribute both ZIPs together.

AV1 playback on M1 uses software decoding. Long GOPs can cause a delay on a distant exact seek. Nearby forward seeks reuse the decoder, and frame steps use a bounded cache. Playback can resume from cached video and audio; pause keeps the queued media ready. During a cold start the last image stays visible until playback is ready. Some unusual AVI timestamp layouts, Dolby Vision dynamic metadata, and sustained playback of very demanding AV1 files need broader real-world testing. HDR color transfer and primaries are covered by the synthetic tests; Dolby Vision metadata preservation is not claimed.

## Subtitle review build

See [the subtitle handoff](docs/feature-work/hardsubs-handoff.md) for usage,
validation, limitations and the private review artifacts. Build a separately
named app with `CLIPPER_REVIEW_BUILD=1 bash scripts/build-app.sh` and package it
with `CLIPPER_REVIEW_BUILD=1 bash scripts/package-release.sh` after committing.
The review bundle has its own identifier and no Finder document registration.

## URL range review build

`bash scripts/package-url-range-review.sh` creates a separately named review app and matching source ZIPs after a clean commit. It removes Finder document registrations from the review bundle and preserves the production version. See `docs/feature-work/url-range-import-handoff.md` for focused validation and current limitations.
