# Architecture and UI decisions

## Product boundaries

Clipper edits one local or URL-imported video and exports one selected MP4 clip at a time. Frame selection follows decoded presentation timestamps, including variable-frame-rate sources. Start and End are the first and last included frames. Export translates the last frame into an exclusive boundary and re-encodes the selected picture with source timing scaled by the selected speed.

The controls expose clip speed, crop, downscale, hardware H.264/HEVC, one quality value, audio selection/mute and optional subtitle burn-in. Speed scales source timing while preserving every selected frame. There is no proxy preparation step, software video encoding fallback, lossless smart cut, multi-range queue or session recovery.

## Media path

SwiftUI and AppKit provide the shell. `Sources/CMedia/CMedia.m` owns libav demux/decode, exact decoded-frame selection and bounded video/audio caches. `CWaveform.m` extracts audio peaks and `Subtitles.m` handles subtitle discovery and libass rendering. Software decode is allowed when the hardware cannot decode a source codec, including AV1 on M1.

`Playback.swift` sends source frames and PCM to AVSampleBufferDisplayLayer and AVSampleBufferAudioRenderer on one AVSampleBufferRenderSynchronizer. Warm pause/resume retains queued samples and the last image. `LoopPreparation.swift` prepares a second decoder for the next loop pass; bounded cached passes cover very short selections. Generation/cancellation checks reject stale seek, loop and source-load results.

`Export.swift` invokes the bundled LGPL FFmpeg helper using the same source timestamps and decoded-frame boundaries. VideoToolbox encoders run with `allow_sw=0`. Crop/scale never enlarges the crop. Audio is trimmed and re-encoded to stereo AAC. HDR uses HEVC Main10; explicit SDR conversion tone-maps it. HDR subtitle burn-in currently requires SDR conversion.

`ClipSpeed` defines per-clip presets from 0.25× to 4×. Source playback changes the render synchronizer rate with spectral audio pitch correction. Export retimes video after subtitle burn-in and chains pitch-preserving audio tempo filters. Non-normal exports use the filter time base to retain VFR precision and scaled packet durations for the final frame. Trim, loop bounds, subtitles and the timeline stay in source time; encoded-preview seeking, comparison, frame steps and audition convert between source and output time. Preview length and progress use output duration.

A five-second quality preview uses the export pipeline. AVPlayer displays that finished MP4. In Compare, the encoded sample drives the clock while coalesced source-frame requests follow it. Paused seeks and steps align both pictures to decoded source boundaries. One persistent source display layer and one encoded layer share crop geometry; moving the wipe updates existing layers without animations or duplication.

`Subtitles.swift` discovers container text tracks and imports external SRT/WebVTT/ASS/SSA into owned snapshots. libass supplies the live overlay and export burn-in. Authored ASS layout uses source coordinates; common/override styling uses output coordinates. Jobs retain their own snapshots and fonts so asynchronous replacements do not delete files still in use.

## Editor state and persistence

`Editor.swift` coordinates source lifetime, trim, settings, transport, previews, export and feature controllers. Atomic settings updates normalize crop geometry once and refresh dependent preview, waveform and subtitle work. Undo snapshots retain exact trim frames and settings; one completed gesture creates one undo entry. The edit UndoManager is separate from AppKit text undo and clears when the source changes. Subtitle controls and navigation are outside that history.

`ExportPreferences.swift` persists explicit codec/quality choices and the last confirmed save folder. Automatic HDR codec selection never overwrites the SDR preference. Per-video trim, speed, resolution and audio reset on open. Save As remembers its folder on confirmation even if rendering later fails.

`ExportHandoff.swift` provides file pasteboard/drag items and Finder reveal for the completed output. Publication protects source paths and file identity, including symlink/hard-link aliases. Confirmed output replacement happens only after a successful sibling-temp render; failure or cancellation preserves the existing output.

`AudioWaveform.swift` generates bounded peaks for the selected audio track while idle. Playback, seeking and export pause that work. It caches two completed tracks until source close and adapts peak spacing for long files.

## URL import

`ManagedImportTools.swift` installs and updates official standalone yt-dlp and Deno outside the bundle, verifies their hashes/architecture/version, and keeps a previous installation for recovery. `URLImport.swift` manages format lookup, download, cancellation and retry. `ImportWorkspace.swift` leases disposable source directories and cleans abandoned workspaces without deleting a running instance's files.

`ImportRange.swift` represents the requested original-video range and verified time mapping. Ranged downloads retain timestamps, omit subtitle/data tracks, then stream-copy into a normalized local source. Display and typed times use the measured offset; source playback, frame selection and exports keep local time. Unverifiable mapping offers an explicit full-download retry.

The private FFmpeg build supports HTTPS through macOS SecureTransport. The dated patch in `patches/` turns peer certificate verification on by default, including nested requests and redirects. Remote range inputs use a protocol whitelist and a 30-second I/O timeout. Full tool/update behavior and input limits are in the [usage guide](guide.md).

## Native UI

The current design is Compact, selected from the integrated-window-controls study after the Floating glass design and C1. One window-wide material sits behind floating inspector and timeline panels. The inspector is 300 points wide; outer insets and panel gaps are 8 points. The preview selector aligns with the inspector's top; the video shares the timeline column's horizontal bounds, preserves aspect ratio and ends 8 points above it. There is no top rule above the timeline.

The scene hides the window title strip and uses a real empty unified AppKit toolbar. AppKit retains and positions its standard window buttons, including their renderer, shared hover region and green-button tiling. Read-only button geometry sets the header height and filename clearance; full screen releases that clearance. Do not reparent or manually move the buttons, which leaves native group hover tracking behind. Native content-size limits match the full-window workspace. Only static file-header space extends window dragging.

Glass and shadows belong on control/panel shapes, separate from live media layers. Applying compositing, glass or a shadow directly to the video can break native layer ownership or clipping. Keep one persistent source display layer. The app follows system appearance, uses native glass only on macOS 26+, and supplies older-system and Reduce Transparency fallbacks.

Keep source opening in the empty state and preview/export actions pinned below settings. Hide irrelevant audio controls and redundant one-track pickers. The export folder segment opens Save As directly. Timeline shortcuts use separate keycaps; the scrollbar is visible when needed. Preview modes explain their disabled state on hover.

Historical visual sources remain on `prototype/ui-studies` at `eaa1ee3`, `prototype/c-refinements` at `f012eb9`, and `prototype/native-glass` at `083c486`. The Compact studies remain on `prototype/integrated-window-controls` at `1bc9442`. They are design references; production views are SwiftUI/AppKit.

## Distribution

FFmpeg excludes GPL, nonfree and version3 components and links private shared libraries. The app bundles its media helpers, dylibs and license texts. Matching releases include application/dependency sources, patches and build recipes. Runtime media work never uses Homebrew binaries. See [development.md](development.md) and [third-party notices](third-party-notices.txt).
