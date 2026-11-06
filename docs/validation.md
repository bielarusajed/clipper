# Validation record

Validated on the user's Apple M1 Pro running macOS 27.0.1 with Xcode 27.2.

## 0.3.1 confirmed output replacement

Save As now honors the native replacement confirmation for an existing output. Its validator only rejects the source video. Source protection checks resolved paths and device/inode identity, including symlinks and hard links, both before encoding and at publication. One-click Export still generates a unique name and does not authorize replacement.

The encoder writes to a unique temporary file beside the output. After successful encoding, a confirmed replacement uses FileManager's same-volume replacement operation. Cancellation and failed encoding never remove the existing output first. A destination created during an export to a new filename is not silently replaced.

The original validator regression was observed failing for an existing, non-source output. Six focused tests then passed with the fix, covering validator acceptance, protection of source aliases, no-consent/missing-temp failure preservation, an actual hardware export replacing the output, immediate cancellation preserving that completed output, preview replacement cancellation, and encoded comparison stepping. Claude reviewed the confirmation gate, source identity checks and publication path and found no blockers.

## 0.3.0 floating glass adoption

The user selected the native B prototype and authorized applying it to the main app. The production layout removes the study switcher and environment state, the timeline's top rule, and the video's extra horizontal padding. The selector and inspector share a top edge; the video preserves aspect ratio and sits 12 points above the timeline. One window material spans the app, with native glass panels on macOS 26+ and an older-system fallback.

The native comparison-surface geometry and encoded comparison-step tests both passed. Media processing code is unchanged from the previously passing 22-case run recorded below. The release build compiled and was ad-hoc signed. A native reopen with the supplied WebM confirmed the selector at the inspector top, video and timeline sharing left/right edges, no top rule and no prototype switcher. Claude reviewed the production promotion and agreed with the geometry, material placement, availability guards and removal of prototype dependencies. Small review findings reduced the video shadow near the timeline and restored a subtle thumbnail backing.

## Functional checks

The final 0.2.1 integration run passed all 22 XCTest cases with no skips or failures in 81 seconds, including three optional checks against the supplied 4K60 AV1 WebM. The export check cuts the requested region around 08:13.500–08:20.000 through Clipper's hardware H.264 pipeline at 3840×2160, verifies the frame count and output timestamps, and leaves the source untouched. Selection boundaries snap to decoded presentation times, so a typed sub-frame time is quantized to an actual source frame.

Synthetic fixtures exercise MP4, VFR MKV, VP9 and AV1 WebM, legacy AVI, B-frames, a nonzero container start timestamp, rotation, HEVC HDR and SDR conversion. Both hardware export codecs are tested. Frame identity is checked with uniquely shaded source frames and a tolerance for lossy compression. Cached stepping is checked against decoded VFR frame boundaries. Tests also cover rapid frame-step commands followed immediately by marking the start, and switching to encoded output during a pending source seek.

The pause-during-seek regression failed before the fix with an unmet completion expectation and a permanently true `seeking` flag. It passed after restricting pause invalidation to active playback, as Claude recommended.

C1 tests exercise the real encoded-preview lifecycle, source/output frame alignment, rapid comparison steps followed by play or an I mark, cancelled preview replacement, repeated boundary nudges, rejected timestamp commits, and close-state cleanup. An AppKit layer test checks the rounded export crop coordinates, wipe placement and persistent ownership of the source display layer. A regression near the last H.264 GOP checks backward stepping with and without caches: a seek whose first decoded presentation time is too late now retries from earlier media rather than repeating the following frame.

The 0.2.1 transport regression failed before the fix because Play removed the displayed image and Pause started a fresh seek. It now verifies retained images and warm resume without seeking. Other new checks cover startup cancellation, cached video frame timing/count and sample-aligned audio continuity across H.264, VFR, VP9 and AV1, and exact cached intervals after a forward jump. That last regression caught a stale rendered interval in the faster continuation path; skipped, unconverted frames no longer stretch the previous cached frame's display duration. Divider tests verify that the knob, line and mask move together without adding layers or animations.

## Performance

The sample is 3840×2160 AV1 at 60 fps with Opus audio. On this M1 Pro, AV1 decoding uses software. `scripts/benchmark.sh` measures the actual C media bridge, including native display-buffer creation, at the requested location. The final run passed its thresholds for distant seek latency, real-time decoding and repeated forward/backward frame stepping. Cold seeks still require decoding from a keyframe; the decoded-frame cache is bounded to 512 MiB plus four display samples.

The C1 comparison check requests 30 source updates per second around the user's clip and requires at least 12 delivered updates per second without publishing an editing-seek busy state. Requests coalesce behind a running decode. Encoded playback supplies the clock; paused seeks and frame steps resolve exact source boundaries. This check measures the decode path, not screen presentation or perceived A/V sync.

Before the 0.2.1 changes, three seeks around the requested region measured 674, 611 and 701 ms. With two-second forward decoder reuse they measured 615, 85 and 91 ms. The first cold seek still decodes from a keyframe. Forward/backward frame steps measured 3.2/1.4 ms. A focused real-source transport run measured 16 ms from Play to the renderer clock starting after an exact seek, and under 1 ms for warm resume. These timings measure application/renderer state, not physical display or audio latency. The frame cache remains bounded to 512 MiB plus four rendered samples; the added 128-entry PCM audio ring uses about 1 MiB for typical AAC/Opus packets.

## Claude review

Two independent Claude reviews covered implementation risks and agreement with `docs/plan.md`. Findings drove fixes for interrupted file loading, cancelled seek state, queued keyboard commands, text-field shortcuts, playback flush ordering, export cleanup at quit, anamorphic/rotated crop geometry, color tags, thumbnail generation, reverse-frame caching and stale dependency packaging.

A subsequent Claude re-check agreed with those fixes and identified the pause-during-seek race. The focused failing regression and final passing suite verify its recommended correction. No review findings were intentionally deferred as functional blockers.

For C1, Claude reviewed the comparison architecture before implementation and completed two code reviews. Fixes preserve preview range metadata until a replacement succeeds, serialize repeated boundary nudges, defer playback commands during comparison steps, restore rejected timestamp text, prevent Save As replacement, expose selected accessibility states, and reject stale backdrops from previously opened sources.

A focused Claude review agreed with the new exact-seek fallback and found no blockers in its selection logic, termination, cancellation, ownership or audio handling. Approximate timeline thumbnails and the direct playback-start seek still use the original demuxer seek path. The exact fallback applies to paused editing and comparison frame selection.

For 0.2.1, Claude challenged eager playback priming and retaining a second buffer history. We adopted on-demand replay of the existing current-segment video cache plus a bounded PCM audio ring, and retained timing metadata for pause resolution. Claude's code review agreed with the cache and UI changes and found a startup-cancellation state bug. Pause/chase/EOF now clear or cancel startup state, with a focused quick Play/Pause/Play regression.

## Packaging and visual checks

The app uses self-built FFmpeg, dav1d and zimg libraries. Their deployment targets are macOS 14. The library graph is rewritten to bundle-relative paths; signing is ad-hoc. The build stages a fresh app before replacing the old one, so it never overwrites a running executable. The release script requires a clean Git tree and includes the matching application and dependency sources.

macOS 14 compatibility is a deployment target and link check, not a runtime test on an older Mac. Developer ID signing and notarization remain deferred by user agreement.

Native UI checks earlier in the session covered opening a WebM, the editor's loaded state, frame controls and playback. The final reopen check could not capture the window through the remote computer-use service, which reported `cgWindowNotFound` while listing Clipper as running. The latest playback/editor changes are covered by automated tests; final manual UI validation remains limited by that remote session.

The native window service worked during the 0.2.1 follow-up. Checks on the supplied WebM confirmed clicks inside two formerly hollow framing icons change presets repeatedly, the one-track picker is hidden, Exclude audio and Resolution align correctly, and the split folder button opens Save As directly. Comparison dragging was checked in both directions, with one visible divider and matching accessibility values at 19% and 80%. Cmd+equals increased timeline zoom by 0.5. The later label/keycap cleanup is checked by building the native views. Physical trackpad pinch and subjective screen/audio latency still need hands-on verification.

The user selected C from three HTML studies, then C1 from two refinements. C1 is implemented in the production SwiftUI/AppKit editor, including the frosted left sidebar, pinned export controls, comparison wipe and timeline overview. The original studies remain on `prototype/ui-studies`; the refinements remain on `prototype/c-refinements`. Their screenshots are design references, not captures of the native build.
