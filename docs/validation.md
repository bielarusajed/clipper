# Validation record

Validated on the user's Apple M1 Pro running macOS 27.0.1 with Xcode 27.2.

## Functional checks

The final C1 integration run passed all 17 XCTest cases with no skips or failures in 64.6 seconds, including two optional checks against the supplied 4K60 AV1 WebM. The export check cuts the requested region around 08:13.500–08:20.000 through Clipper's hardware H.264 pipeline at 3840×2160, verifies the frame count and output timestamps, and leaves the source untouched. Selection boundaries snap to decoded presentation times, so a typed sub-frame time is quantized to an actual source frame.

Synthetic fixtures exercise MP4, VFR MKV, VP9 and AV1 WebM, legacy AVI, B-frames, a nonzero container start timestamp, rotation, HEVC HDR and SDR conversion. Both hardware export codecs are tested. Frame identity is checked with uniquely shaded source frames and a tolerance for lossy compression. Cached stepping is checked against decoded VFR frame boundaries. Tests also cover rapid frame-step commands followed immediately by marking the start, and switching to encoded output during a pending source seek.

The pause-during-seek regression failed before the fix with an unmet completion expectation and a permanently true `seeking` flag. It passed after restricting pause invalidation to active playback, as Claude recommended.

C1 tests exercise the real encoded-preview lifecycle, source/output frame alignment, rapid comparison steps followed by play or an I mark, cancelled preview replacement, repeated boundary nudges, rejected timestamp commits, and close-state cleanup. An AppKit layer test checks the rounded export crop coordinates, wipe placement and persistent ownership of the source display layer. A regression near the last H.264 GOP checks backward stepping with and without caches: a seek whose first decoded presentation time is too late now retries from earlier media rather than repeating the following frame.

## Performance

The sample is 3840×2160 AV1 at 60 fps with Opus audio. On this M1 Pro, AV1 decoding uses software. `scripts/benchmark.sh` measures the actual C media bridge, including native display-buffer creation, at the requested location. The final run passed its thresholds for distant seek latency, real-time decoding and repeated forward/backward frame stepping. Cold seeks still require decoding from a keyframe; the decoded-frame cache is bounded to 512 MiB plus four display samples.

The C1 comparison check requests 30 source updates per second around the user's clip and requires at least 12 delivered updates per second without publishing an editing-seek busy state. Requests coalesce behind a running decode. Encoded playback supplies the clock; paused seeks and frame steps resolve exact source boundaries. This check measures the decode path, not screen presentation or perceived A/V sync.

## Claude review

Two independent Claude reviews covered implementation risks and agreement with `docs/plan.md`. Findings drove fixes for interrupted file loading, cancelled seek state, queued keyboard commands, text-field shortcuts, playback flush ordering, export cleanup at quit, anamorphic/rotated crop geometry, color tags, thumbnail generation, reverse-frame caching and stale dependency packaging.

A subsequent Claude re-check agreed with those fixes and identified the pause-during-seek race. The focused failing regression and final passing suite verify its recommended correction. No review findings were intentionally deferred as functional blockers.

For C1, Claude reviewed the comparison architecture before implementation and completed two code reviews. Fixes preserve preview range metadata until a replacement succeeds, serialize repeated boundary nudges, defer playback commands during comparison steps, restore rejected timestamp text, prevent Save As replacement, expose selected accessibility states, and reject stale backdrops from previously opened sources.

A focused Claude review agreed with the new exact-seek fallback and found no blockers in its selection logic, termination, cancellation, ownership or audio handling. Approximate timeline thumbnails and the direct playback-start seek still use the original demuxer seek path. The exact fallback applies to paused editing and comparison frame selection.

## Packaging and visual checks

The app uses self-built FFmpeg, dav1d and zimg libraries. Their deployment targets are macOS 14. The library graph is rewritten to bundle-relative paths; signing is ad-hoc. The build stages a fresh app before replacing the old one, so it never overwrites a running executable. The release script requires a clean Git tree and includes the matching application and dependency sources.

macOS 14 compatibility is a deployment target and link check, not a runtime test on an older Mac. Developer ID signing and notarization remain deferred by user agreement.

Native UI checks earlier in the session covered opening a WebM, the editor's loaded state, frame controls and playback. The final reopen check could not capture the window through the remote computer-use service, which reported `cgWindowNotFound` while listing Clipper as running. The latest playback/editor changes are covered by automated tests; final manual UI validation remains limited by that remote session.

The user selected C from three HTML studies, then C1 from two refinements. C1 is now implemented in the production SwiftUI/AppKit editor, including the frosted left sidebar, pinned export controls, comparison wipe and timeline overview. The original studies remain on `prototype/ui-studies`; the refinements remain on `prototype/c-refinements`. Their screenshots are design references, not captures of the native build. The remote window-service failure above still limits final native visual validation.
