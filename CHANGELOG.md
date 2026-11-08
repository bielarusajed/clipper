# Changelog

## 0.5.4 · 8 November 2026

- Restore the current macOS appearance of native window controls. Pin the SwiftPM build engine and reject binaries whose linked SDK differs from the selected SDK; a build-engine change had stamped recent apps with SDK 14.0 despite compiling against SDK 27.2.
- Preserve the Compact layout and native hover behavior. The minimum supported macOS remains 14.

## 0.5.3 · 8 November 2026

- Mitigate source-preview compositing flicker with slight group blending, and restore rounded video clipping. Exported pixels are unchanged.

## 0.5.2 · 7 November 2026

- Adopt the Compact window layout, with 8-point panel gaps and native traffic lights inside the inspector header. Remove the separate title strip and prototype switcher.
- Keep AppKit in charge of window-button placement, glass rendering, shared hover glyphs and tiling. The header measures the native controls rather than moving them.
- Fit video and window limits to the whole window, including tall sources. Keep transparent chrome stable while source metadata changes.

## 0.5.1 · 7 November 2026

- Keep the title bar transparent after SwiftUI refreshes or a video opens. Hide the duplicated window title and separator so the top shares the window material. Native glass, system light/dark appearance and Reduce Transparency behavior are unchanged.

## 0.5.0 · 7 November 2026

- Archived builds no longer accumulate in Finder's Open With menu. Builds unregister old copies and keep their contents in folders without the `.app` suffix.
- Undo and redo for trim, framing and export settings, with one entry per completed gesture and native text-field undo.
- Selection looping with a prewarmed decoder, plus a last-second cut audition that holds the final included frame.
- Copy and drag completed exports into other apps, alongside Show in Finder.
- Optional audio waveform for the selected track, generated in the background with bounded memory.
- Rough URL range downloads with padding and verified original-video timestamps for precise editing after import.
- Remembered codec, quality and save folder, with HDR preserving the preferred SDR codec.
- Burned-in container or external SRT, WebVTT, ASS and SSA subtitles. Authored ASS/SSA styles are retained by default; a common configurable style handles unstyled subtitles and optional overrides.
- URL-import cleanup, tool-update recovery and HTTPS certificate-verification hardening.
- Window centering on video open and packaging that uses SwiftPM's resolved binary directory.
- Consolidated usage, architecture and development docs; retired completed feature work orders and review-only packaging. Release ZIPs now include the version in their filenames and have a SHA-256 checksum file.

## 0.4.0–0.4.3 · 7 November 2026

- Managed URL imports through standalone yt-dlp and Deno, with format selection, automatic tool updates and disposable source cleanup.
- Paste URLs, local paths and Finder files into the main window.
- Window sizing follows video aspect ratio and available screen space. Timeline layout reserves space for its persistent scrollbar.

## 0.3.0–0.3.1 · 6 November 2026

- Adopted the floating native glass editor with aligned viewer and timeline.
- Save As honors confirmed replacement of an existing output while protecting the source and preserving the old output on failure or cancellation.

## 0.2.1 and earlier · 6 November 2026

- Precise decoded-frame trimming, zoomable filmstrip, crop presets, downscaling and hardware H.264/HEVC export.
- HDR preservation or explicit SDR conversion, audio selection/mute and an actual five-second encoded comparison preview.
- Warm playback resume, bounded frame/audio caches and comparison-divider interaction fixes.
