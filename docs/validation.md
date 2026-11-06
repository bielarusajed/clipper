# Validation record

Validated on the user's Apple M1 Pro running macOS 27.0.1 with Xcode 27.2.

## Functional checks

The final integration run passed all 10 XCTest cases with no skips or failures. This includes the optional test against the supplied 4K60 AV1 WebM. The test exports the requested region around 08:13.500–08:20.000 through Clipper's hardware H.264 pipeline at 3840×2160, verifies the frame count and output timestamps, and leaves the source untouched. Selection boundaries snap to decoded presentation times, so a typed sub-frame time is quantized to an actual source frame.

Synthetic fixtures exercise MP4, VFR MKV, VP9 and AV1 WebM, legacy AVI, B-frames, a nonzero container start timestamp, rotation, HEVC HDR and SDR conversion. Both hardware export codecs are tested. Frame identity is checked with uniquely shaded source frames and a tolerance for lossy compression. Cached stepping is checked against decoded VFR frame boundaries. Tests also cover rapid frame-step commands followed immediately by marking the start, and switching to encoded output during a pending source seek.

The pause-during-seek regression failed before the fix with an unmet completion expectation and a permanently true `seeking` flag. It passed after restricting pause invalidation to active playback, as Claude recommended.

## Performance

The sample is 3840×2160 AV1 at 60 fps with Opus audio. On this M1 Pro, AV1 decoding uses software. `scripts/benchmark.sh` measures the actual C media bridge, including native display-buffer creation, at the requested location. The final run passed its thresholds for distant seek latency, real-time decoding and repeated forward/backward frame stepping. Cold seeks still require decoding from a keyframe; the decoded-frame cache is bounded to 512 MiB plus four display samples.

## Claude review

Two independent Claude reviews covered implementation risks and agreement with `docs/plan.md`. Findings drove fixes for interrupted file loading, cancelled seek state, queued keyboard commands, text-field shortcuts, playback flush ordering, export cleanup at quit, anamorphic/rotated crop geometry, color tags, thumbnail generation, reverse-frame caching and stale dependency packaging.

A subsequent Claude re-check agreed with those fixes and identified the pause-during-seek race. The focused failing regression and final passing suite verify its recommended correction. No review findings were intentionally deferred as functional blockers.

## Packaging and visual checks

The app uses self-built FFmpeg, dav1d and zimg libraries. Their deployment targets are macOS 14. The library graph is rewritten to bundle-relative paths; signing is ad-hoc. The build stages a fresh app before replacing the old one, so it never overwrites a running executable. The release script requires a clean Git tree and includes the matching application and dependency sources.

macOS 14 compatibility is a deployment target and link check, not a runtime test on an older Mac. Developer ID signing and notarization remain deferred by user agreement.

Native UI checks earlier in the session covered opening a WebM, the editor's loaded state, frame controls and playback. The final reopen check could not capture the window through the remote computer-use service, which reported `cgWindowNotFound` while listing Clipper as running. The latest playback/editor changes are covered by automated tests; final manual UI validation remains limited by that remote session.

The three requested UI alternatives are separate HTML visual prototypes. Their screenshots use a still from the supplied video. They are not changes to the production editor. Full source is preserved on `prototype/ui-studies`; PNG screenshots and the offline switcher are in `dist/prototypes`.
