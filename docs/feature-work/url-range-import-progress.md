# URL range import checkpoint

Updated 7 November 2026, 03:46 Europe/Warsaw. This is a continuation checkpoint, not a completed feature handoff. The feature is not ready to distribute yet.

## Implemented

- Optional start/end controls, full-video import by default, finite endpoints and duration validation, five seconds of padding on each side.
- Immutable download intent, including while format lookup is pending. Format and audio selection remain in use.
- `--download-sections` with `ffmpeg_i1:-copyts -start_at_zero`. No keyframe-forcing or software re-encoding.
- Probe original timestamps, stream-copy to a normalized local MKV, measure the offset as original origin plus new local origin. Decoder, timeline geometry, previews and exports keep local coordinates. Time readouts, timeline labels and typed boundaries convert through the stored offset.
- Coverage checks decode the first and last local video frame. Unverifiable, truncated or rebased results fail with an explicit full-video retry, never an automatic full download.
- Opt-in suggestion from yt-dlp's `start_time` metadata. Timestamp links never turn on the range by themselves.
- Per-worktree import cache override in the test runner.

## Validation so far

Run `bash scripts/test.sh --filter 'URLRangeTests|PasteImportTests.testRangeIntent|URLImportTests'` with hardware/IOSurface access. The sandbox alone blocks macOS media services.

21 tests executed, one opt-in network test skipped, zero failures. Log: `.build/range-tests/groundwork-tests.log`. All 12 PasteImportTests also pass with native isolated windows and named pasteboards; log `.build/range-tests/paste-regression-tests.log`.

The synthetic pipeline uses the existing cfr fixture with B frames and audio, looped locally. Only the remote downloader is replaced by a fixture process. Real FFmpeg, CMedia, hardware encoder, Editor and cleanup run. Tests cover original/local mapping, immutable queued intent, downloader arguments, packet hashes throughout the requested range, exported frame count and image identity, no-audio mapping, cancellation of descendant processes, disposal, invalid ranges and rejection of rebased timestamps. Temporary outputs stay in this worktree or the pre-existing tests' isolated temporary directories.

Empirical source section at requested downloader start 8.5 has first video timestamp 7.980 and earliest audio timestamp 7.877. Matroska's Duration is the absolute end, so the local normalization step is necessary. The no-audio normalized file can have a nonzero local origin; packet timestamps must subtract that origin before applying the stored display offset.

## Blocking dependency question

The baseline media recipe has `--disable-network`. Full imports work because yt-dlp downloads natively and FFmpeg only merges local files. Ranged imports require FFmpeg to read HTTP/HTTPS. No real ranged URL will work until this is resolved.

Proposed next step, sent to Claude but NOT agreed yet: enable networking and macOS SecureTransport explicitly (`--enable-network --enable-securetransport`) with no additional third-party dependency or licensing change. Build FFmpeg in this feature worktree, from a private source extraction and private prefix. The existing `.build/media` and `.build/vendor` are currently READ-ONLY INPUT SYMLINKS into the baseline project's caches. REMOVE THOSE SYMLINKS BEFORE ANY DEPENDENCY BUILD. Never run build-media.sh through them. Copy unchanged dav1d/zimg artifacts privately if helpful, and use a fresh private FFmpeg source tree. Update the reproducible recipe after agreement. Confirm http/https/tls/tcp protocols and hardware-only encoders.

Claude completed two design consultations and agreed on the preserved-then-normalized timestamp design, finite endpoints, explicit full fallback and opt-in hints. Claude then hit its 5-hour rate limit in the dependency consultation, reporting a reset at **08:20 Europe/Warsaw on 7 November 2026**. Do not claim this question or the code review succeeded.

Design consult links:
- <t3-thread://v2/416a334f-4bfa-4837-9595-1b52af7587d9/thread:delegated-task:command%3Amcp%3Aebf1b6b1-89eb-4806-be1a-2d263b1e6be9%3Adelegate-task%3A94df84bb-ca58-49b7-b8d3-5562bb364c1b>
- <t3-thread://v2/416a334f-4bfa-4837-9595-1b52af7587d9/thread:delegated-task:command%3Amcp%3Aebf1b6b1-89eb-4806-be1a-2d263b1e6be9%3Adelegate-task%3A800c716d-59d7-44c6-a96e-a77c12b0436b>
- Rate-limited dependency consult: <t3-thread://v2/416a334f-4bfa-4837-9595-1b52af7587d9/thread:delegated-task:command%3Amcp%3Aebf1b6b1-89eb-4806-be1a-2d263b1e6be9%3Adelegate-task%3Af9ae1afb-3900-4fa2-8787-0a4879672d2f>

Continuation is scheduled in this same thread for **7 November 2026 at 08:25 Europe/Warsaw**, schedule `scheduled-task:e644070c-6738-4674-934c-9e8b375e9ed7`.

## Remaining work, already authorized

1. Re-consult Claude after reset on private network-enabled FFmpeg build. No alternate provider. `orchestrator_capabilities` has already been called in this thread. New delegate for each consultation/review, no polling a running delegate.
2. Build privately and test real managed yt-dlp through a range-capable local HTTP fixture server, plus a representative public URL. Read-only managed tools already exist at `/Users/bielarusajed/.t3/projects/clipper/.build/url-import-integration/Tools`, versions in manifest.json. Prefer copying them privately for test use without managed updates to the shared path. Confirm final file reporting for single and merged formats, source offset containers and A/V timing. Document site limitations honestly.
3. Add targeted coverage for range-failure full retry and duration arriving after intent, and full-download no-range arguments. Consider source nonzero origin fixtures and a rebasing control.
4. Obtain Claude code review against the full approved brief and resolve findings. Current code is not reviewed.
5. Build a self-contained distinct review app. On its staged bundle set `CFBundleName`/`CFBundleDisplayName` to `Clipper URL Range Review` and identifier `app.clipper.video.review.url-range-import`. Remove document-type registration so it does not become a Finder handler. Re-sign after staging changes. Do not change production version.
6. Commit final work, package review ZIP and matching source ZIP with pinned FFmpeg/dav1d/zimg archives, exact recipe, configure log and config.mak, source git archive and notices. Include artifact receipt/commit. Keep all outputs under this worktree's dist. Do not use main, other branches, root dist, pushes, merges or PRs.
7. Replace this checkpoint with concise reproducible final handoff notes and finish with feature usage, validation/limitations, branch/commit and absolute ZIP links.

Primary references checked: yt-dlp tag 2026.10.26 `yt_dlp/downloader/external.py`, downloaded into `.build/range-tests/external.py`; official README at https://github.com/yt-dlp/yt-dlp#download-options. Its downloader adds input `-ss`/`-t`, preserves stream copy unless force-keyframes is enabled, and accepts `ffmpeg_i1` options before the first input.
