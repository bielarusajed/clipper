# Rough URL range import review

The original review build on `feature/url-range-import` is based on planning commit `3f1c9662` and Clipper 0.4.3. Its matching-source receipt identifies commit `b473e02`.

## Try it

Open `dist/Clipper URL Range Review.app`. Import URL, paste a video link, enable Import a rough time range, and enter `08:00` to `08:30` for a cut near `08:13.5`. Download, then adjust the amber selection or type exact original-video timestamps. End is the last included frame, as in the existing editor. Export Clip uses the existing hardware-only encoder and Save dialog. Uncheck the range for the usual full-video download.

A link timestamp suggestion never enables a range on its own. The importer fetches five seconds of padding at each end, plus earlier keyframes. It validates again after format lookup when duration becomes available. Unsupported ranges offer an explicit full-video retry. The selected video/audio formats and managed tool lifecycle are preserved.

## Time mapping and dependencies

The downloader keeps source timestamps relative to the original source's start. Clipper probes them, makes a local stream copy to normalize the file, and stores the measured original-to-local offset. Only display and typed timestamps convert through that offset; decoder seeks, frame points, preview and export continue using local time. First/last decoded frames must cover the requested range. An unverifiable mapping fails rather than guessing the original time.

FFmpeg 8.0.1 now includes networking and macOS SecureTransport. The dated LGPL source patch in `patches/` enables TLS certificate verification by default, including nested requests and HTTP redirects. Input protocols exclude local files and use a 30-second I/O timeout. No software video encoders or new third-party dependencies are added. The media build used private source and prefix copies; shared dependency caches were read-only inputs. Package receipts include the exact git commit, app hashes, dependency archives, configure log, config.mak, patch and patch hash.

## Reproduce

- `bash scripts/test.sh --filter 'URLRangeTests|URLImportTests|PasteImportTests'` tests parsing, arguments, pending intents, native import windows, time mapping, packet/frame identity, hardware trimming and cleanup. macOS VideoToolbox/IOSurface access is required.
- For real downloader fixtures, place official standalone yt-dlp and Deno binaries at `.build/range-tests/Tools/yt-dlp` and `deno`, then run `CLIPPER_RANGE_NETWORK_TEST=1 bash scripts/test.sh --filter URLRangeTests`. The test server binds only to loopback and shuts down after testing. The fixtures include combined, separate audio/video, and nonzero-start MP4/TS sources.
- `CLIPPER_RANGE_PUBLIC_TEST=1 bash scripts/test.sh --filter URLRangeTests` also tests Blender's public HTTPS trailer and invalid TLS peers. Public availability is outside Clipper's control.
- `bash scripts/package-url-range-review.sh` requires a clean commit and builds `dist/Clipper-URL-Range-Review-macOS-arm64.zip` and `dist/Clipper-URL-Range-Review-Sources.zip`. Distribute together. The source archive contains the same recipe and patches. Production app version remains 0.4.3.

## Limits and integration overlap

Range downloads use indeterminate progress because yt-dlp's FFmpeg downloader does not report useful transfer percentages. Some servers and unindexed formats still transfer most of the source; network savings are not promised. Live/DRM/authenticated inputs and some HLS variants remain unsupported. Sources whose retained keyframe is over 60 seconds before the padded start fail timestamp verification. Source-edge coverage allows up to one second of site-duration rounding; interior cuts require the requested coverage. Range files omit subtitles/data and disable automatic yt-dlp fixups, including rare stretched-aspect corrections. Matroska rounds timestamps to milliseconds; frame identity and inclusive trim boundaries remain based on decoded frames. Local original files are untouched.

This overlaps sibling work around importer UI, Editor time readouts, timeline labels and media packaging. Integrate those changes deliberately. This review app is ad-hoc signed, targets Apple Silicon/macOS 14+, and is not notarized.

## Validation and review

Claude reviewed the implementation and found no blocking issues. The recommended fixes are included: bounded tolerance for rounded durations at the source edge, explicit fallback only after transfer starts, local-file typed-time clamping, and an exact reverse-dry-run check of the applied TLS patch. Verification decoding supports cancellation. The importer window resizes with its content; the compact-height constant is its initial size.

- 31 importer/editor/hardware/TLS tests passed, with the pre-existing optional managed-install network test skipped. Log: `.build/range-tests/verified-import-tests.log`.
- All 8 dedicated range tests passed with real yt-dlp, loopback HTTP/TLS, offset MP4/TS, separate video/audio, subtitle/timecode tracks and the public Blender HTTPS `.m4v` trailer. Log: `.build/range-tests/final-range-tests.log`.
- The source-edge and typed-time review fixes passed 16 targeted tests. Log: `.build/range-tests/review-fixes-tests.log`.
- The native range-controls layout and early-validation fallback checks also pass. Log: `.build/range-tests/range-layout-tests.log`.
- `scripts/check-media.sh` confirms HTTPS/SecureTransport, the matching patch hash and the binary's TLS verification default of 1. Reverse-dry-run confirms the exact source patch is applied. Shell syntax and whitespace checks pass.

External badssl certificate hosts produced inconsistent network responses, so the repeatable trust test uses a private self-signed loopback certificate and requires SecureTransport's certificate-chain rejection. No system trust settings were changed. Valid public HTTPS was tested separately. No universal site compatibility or bandwidth savings are claimed.

The final build receipt in the matching source ZIP identifies the exact commit and every bundled file hash. Both ZIPs are in this worktree's `dist/` folder. Review code: <t3-thread://v2/416a334f-4bfa-4837-9595-1b52af7587d9/thread:delegated-task:command%3Amcp%3Aebf1b6b1-89eb-4806-be1a-2d263b1e6be9%3Adelegate-task%3A5fe9a7b5-8d2a-45fa-8ff9-2addfa0813c0>.

## PR conflict resolution

PR #4 now incorporates `main` at `61d39b1`. The resolution preserves importer tool-refresh recovery, asynchronous cleanup and workspace leases alongside the rough range and timestamp metadata. Editor source reset also preserves export preferences, exported-clip handoff and waveform cleanup. Regression checks cover a queued range surviving tool refresh and an active ranged source surviving abandoned-workspace cleanup.

The merge regression suite passed 82 tests with four optional network tests skipped. A separate run passed both real yt-dlp HTTP range fixtures and local TLS certificate rejection with workspace leases enabled. The existing review ZIPs still represent `b473e02`; this merge updates the PR source without replacing those original review artifacts.
