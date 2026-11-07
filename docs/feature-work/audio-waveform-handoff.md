# Audio waveform review

Implemented on `feature/audio-waveform`, independently from planning commit `3f1c9662e3113bbbd61d53d1c29fa8611b008fd0`. The app and source packages both contain `SourceRevision.txt` identifying their exact implementation commit. Production remains Clipper 0.4.3. No merges, pushes or PRs are part of this work.

## Try it

1. Unzip `dist/Clipper-Waveform-Review-macOS-arm64.zip` and open **Clipper Waveform Review.app**. It is ad-hoc signed for Apple Silicon, macOS 14 or later. Its bundle identifier is `app.clipper.review.audio-waveform`; Finder video-handler registration is removed.
2. Open a video with audio. Click the waveform button immediately left of timeline zoom, or choose View → Show Audio Waveform. Pause playback while it generates. The waveform appears below the filmstrip after generation completes.
3. Zoom into speech or a short transient. Click the waveform to seek, or drag the existing amber handles. Both rows share the same source-time coordinates and selection. The window and timeline retain their existing height.
4. Choose another source audio track in the inspector. Completed tracks return immediately from a two-track cache. Excluding audio from export dims the source waveform. Videos without audio show neither the waveform nor its toolbar toggle.

The toggle starts off at launch and keeps its setting while the app stays open. Peaks and caches are discarded on source replacement or close. They are not saved to disk. The review app uses the existing managed URL-import tools directory, as stable Clipper does.

## Generation and limits

The independent libav reader decodes only the selected audio stream with one decoder thread. It uses decoded frame presentation timestamps, the playback origin and the playback stream index. Encoder priming, stream offsets, silence and VFR video therefore use the same timeline as trimming. Peaks take the absolute maximum across channels without downmix cancellation or resampling. A fixed −54 dB display floor makes quiet audio visible without normalizing each track.

Generation starts after 300 ms idle. Playback, seeks, comparison preparation and export pause it between bounded batches. Hiding the waveform, changing tracks and closing the source cancel the current job. Demux opening, probing and reads have an interrupt callback. A cancelled managed-import job retains its source lease until its reader closes. Quit cancels and joins the worker before explicit source disposal.

Initial generation reads the audio from start to end and shows progress until all peaks are ready. Long interleaved MKV/WebM sources may need substantial disk reading; there is no partial waveform display in this version. Continuous playback keeps generation paused. Unsupported or untimestamped audio shows a nonblocking unavailable message; toggle off and on to retry.

Resolution is approximately 5 ms up to 5,000 seconds, then coarsens to keep at most 1,000,000 Float32 bins. A 100,000-second source uses approximately 100 ms bins. Reduction levels support rendering a fitted long source without scanning all its bins on every redraw. Each completed track uses at most about 8 MB of peaks and reduction levels; two completed tracks use about 16 MB. An uncached generation temporarily adds up to another 8 MB, plus libav's decoder/frame/demux buffers. No complete PCM recording is retained.

## Validation

Claude agreed on the plan and reviewed the code. The review's buffer-boundary finding was fixed in C accumulation and Swift rendering, with an adversarial rounded-division regression test. Invalid compressed packets are skipped on send/receive; missing initial timestamps still fail explicitly. Cancellation with an open, paused reader has a dedicated test. The minor possibility of cancelling and restarting a paused job while a track reload restores the corrected video duration remains; the 300 ms debounce prevents those intermediate jobs from decoding.

The final focused native run passed **13 tests**, including ten waveform tests and the existing timeline and window-fit tests. Reproduce with:

```sh
bash scripts/make-waveform-fixtures.sh
bash scripts/test.sh --filter 'WaveformTests|TimelineTests|EditorWindowTests'
```

The fixture script defaults to the separate test-only software FFmpeg at `/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg`. Override `FIXTURE_FFMPEG` if needed. Native GUI tests need WindowServer access. Under the restricted shell sandbox, AppKit initialization aborted through XCTest's async runtime; the native run passed.

Coverage includes known opposite-polarity stereo peaks, two selected tracks with +350 ms and +100 ms audio offsets in a +7-second VFR container, AAC and Opus priming, source replacement/no-audio, zoom and fixed-height rendering, pause/resume/cache invalidation, cancellation before open and between batches, managed-source retention, a real 180-second decode and a sparse 100,000-second source. The long-source peak pyramid stayed below 8,000,100 bytes. Measured burst onset at the 25% threshold was 0.500 seconds for AAC and 0.505 seconds for Opus, against a 0.500-second target. Lossless offset peaks were within one 5 ms bin, including container timestamp quantization.

An early combined native run had intermittent window-fit failures. Both the unchanged planning baseline and the feature's isolated recheck passed, followed by the final complete 13-test run. Full hardware-export and broad format suites were not rerun for this focused feature. Encoding and output replacement code are unchanged.

Logs and fit/deep-zoom rendering captures are in this worktree's `.build/waveform-final-tests.log` and `.build/waveform-timeline-{0,1}.png`.

## Build and redistribute

```sh
bash scripts/package-waveform-review.sh
```

Run from a clean committed branch. The script builds the normal app privately, stages the review name and identifier, removes Finder handlers, re-signs it and packages both app and matching sources. No media dependencies or configure options changed. The existing `/Users/bielarusajed/.t3/projects/clipper/.build/media`, `vendor` and `media-configure.log` inputs were reused through read-only access. Mutable Swift builds, caches, fixtures, logs and output stayed under this feature worktree.

Distribute both ZIPs together:

- `dist/Clipper-Waveform-Review-macOS-arm64.zip`
- `dist/Clipper-Waveform-Sources.zip`

The source package includes the exact repository archive, FFmpeg/dav1d/zimg source archives, configuration receipts, build recipes and notices. The review app bundles its FFmpeg tools and transitive libraries and needs no Homebrew installation for local editing. Developer ID signing and notarization remain deferred, as in stable Clipper.

Likely integration overlap is in `Editor.swift`, `Timeline.swift` and `ClipperApp.swift` with the undo, loop/audition and export-preferences branches. No sibling implementation was imported.
