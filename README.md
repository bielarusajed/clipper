<img src="assets/icon.svg" width="64" height="64" alt="">

# Clipper

A native Mac app for cutting a precise clip without setting up a video editor. Drop a video, mark its start and end, adjust the framing if needed, and export an MP4.

## Use

Open `dist/Clipper.app`. The app includes its media engine and needs no Homebrew or terminal. Local editing works offline. URL imports download their tools automatically on first use. The build targets Apple Silicon Macs running macOS 14 or newer. This first build is ad-hoc signed. Shared copies may need approval in System Settings → Privacy & Security on first launch. Developer ID signing and notarization are deferred.

- Open MP4, MOV, MKV, WebM, and AVI through the file picker, drag and drop, or Finder's Open With.
- Start in a compact window. Opening a video restores the editor width and fits its height to the video and controls. The current screen's available area, excluding the menu bar and Dock, limits the window height. Tall videos narrow the window to fit; closing a video returns to the compact starter.
- Paste a URL into the main window with Cmd-V or Edit → Paste to open the compact importer and start loading formats in the background. Download and the format button reuse that lookup; opening the table while it is loading shows its current status. Copied Finder video files, local file URLs and readable video paths open directly. Pasting into editable text fields keeps the normal text-editing behavior.
- Choose Import URL in the empty state or File → Import URL (Shift-Cmd-O). Paste a URL and press Download to import with `bv+ba/b`. Cmd-Enter or the split button's format icon opens a table with format IDs, containers, resolutions, frame rates, sizes and codecs. Select one video and an audio stream, or No audio. Combined formats keep their included audio unless No audio is selected. Enter downloads the current selections in the extended view. Background prefetch leaves both button segments available. Opening formats or requesting Download reveals progress inside the button and changes the format icon to cancel. The title-bar close button cancels work and closes the import window. Audio-only imports are not supported.
- Downloaded sources are disposable temporary files, removed when the video closes, is replaced, or Clipper quits. Export Clip opens a Save dialog for imported sources in the last confirmed Save As folder, falling back to Downloads. Exported clips survive source cleanup. Local source files keep their existing export behavior. Playlists, live streams, DRM, and authenticated browser-cookie imports are not supported. Supported sites depend on the current [yt-dlp release](https://github.com/yt-dlp/yt-dlp).
- Clipper manages official standalone yt-dlp and Deno releases in `~/Library/Application Support/Clipper/Tools`, independently of app releases. It checks for stable updates once per day when importing. It verifies SHA-256, Mac architecture, and reported version before switching, and retains the previous version. A failed update uses the installed tool. First use requires internet access to GitHub. System yt-dlp, Python, Deno, and FFmpeg installations are not used. Downloads trust GitHub over HTTPS and GitHub's published checksums; Clipper does not independently verify upstream GPG signatures. The [Deno runtime is required by current YouTube extraction](https://github.com/yt-dlp/yt-dlp/wiki/EJS). Proxy environment variables are passed through; automatic macOS proxy configuration is not translated into yt-dlp settings.
- Scrub the filmstrip, drag the amber selection edges, and zoom down to individual frame boundaries.
- Zoom with Cmd+plus/Cmd+minus or pinch the timeline. Cmd+0 fits the whole video. The horizontal scrollbar stays visible while the timeline can scroll.
- Use Left/Right to step frames, Space to play/pause, I for the start, and O for the last included frame. Editable timestamps accept seconds or `hh:mm:ss.sss`.
- Crop to Original, 16:9, 9:16, 1:1, 4:5, or a custom ratio. Drag the crop and its lower-right resize handle.
- Keep original resolution or downscale. Presets limit the longest edge and never enlarge the crop.
- Choose H.264 or H.265 and a quality setting. Video export uses VideoToolbox hardware encoding only. Unsupported encoder sizes produce an error rather than falling back to software.
- Codec and quality choices are remembered between videos and app launches. HDR temporarily requires H.265 without changing the preferred SDR codec. Convert to SDR restores that preference. Save As and imported-source save dialogs start in the last confirmed Save As folder, or Downloads if none is saved or the folder is unavailable. If Downloads is also unavailable, the dialog starts in your home folder. Trim, crop, resolution and audio choices reset with each video.
- HDR selects HEVC Main10. Convert to SDR explicitly for SDR sharing. Exclude audio with the switch, or choose a track when the source has several. Sources without audio hide the audio section. Audio exports as stereo AAC; subtitles are omitted.
- Preview 5 Seconds renders a sample beginning at the playhead, bounded to the selection. Switch between original and output. Editing invalidates the sample.
- Floating glass panels hold the left settings and the timeline over one shared window material. The video fills the timeline column width when its aspect ratio allows, and the preview selector aligns with the top of the inspector. The app follows system light/dark appearance. Native glass is used on macOS 26 or newer, with a material fallback on earlier versions.
- Preview/export stay pinned below the left settings. Close the source with its × button to return to the Open Video empty state.
- After rendering a preview, choose Compare and drag the wipe to inspect the original crop beside the encoded output. Forward/backward steps align both halves. The episode overview pans the zoomed timeline without changing the clip.
- Export Clip writes a unique filename beside the source. Its right-hand folder button opens Save As directly and honors macOS's Replace confirmation for an existing output. The source video is protected. Replacement happens only after rendering succeeds; cancelling or a failed render leaves the previous output intact.

## Build

Install Xcode and complete its first-run setup. Run:

```sh
bash scripts/build-app.sh
```

On the first build, the scripts download and build FFmpeg 8.0.1, dav1d 1.5.4, and zimg 3.0.6. Python 3, a C/C++ compiler and make are build-time requirements. Meson and Ninja are installed into a project-local virtual environment. No Homebrew library is required by the finished app. Build output and downloaded sources stay in `.build/`; the app is in `dist/`.

```sh
bash scripts/make-fixtures.sh   # Uses a separate test-only FFmpeg with software encoders.
bash scripts/test.sh
bash scripts/benchmark.sh /path/to/video.webm 493.5
```

The tests exercise real decoding, cached frame steps, VFR selection, hardware H.264/HEVC output, frame identity and count, crop geometry, rotation, HDR and SDR conversion. VideoToolbox and IOSurface access are required. Set `CLIPPER_SAMPLE` to a long 4K source to include the sample export test.

## Media engine and distribution

SwiftUI/AppKit controls sit above libav demux/decode and Apple's sample-buffer video and audio renderers. The decoded presentation timestamps determine selection boundaries. No proxy conversion is needed. Export uses the same FFmpeg build and source timestamps, then re-encodes with the hardware encoder. The original file is never modified.

The FFmpeg build excludes GPL and nonfree components. Shared libraries, licenses and credits are included in the bundle. Run `bash scripts/package-release.sh` to create the app ZIP and a matching source ZIP with all dependency sources, exact build recipes and package receipts. Distribute both ZIPs together.

AV1 playback on M1 uses software decoding. Long GOPs can cause a delay on a distant exact seek. Nearby forward seeks reuse the decoder, and frame steps use a bounded cache. Playback can resume from cached video and audio; pause keeps the queued media ready. During a cold start the last image stays visible until playback is ready. Some unusual AVI timestamp layouts, Dolby Vision dynamic metadata, and sustained playback of very demanding AV1 files need broader real-world testing. HDR color transfer and primaries are covered by the synthetic tests; Dolby Vision metadata preservation is not claimed.
