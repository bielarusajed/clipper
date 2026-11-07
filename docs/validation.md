# Validation and known limits

## 0.5.0 integration

Release validation uses the merged application on an Apple M1 Pro with macOS 27.0.1 and Xcode 27.2. All seven feature suites are integrated on main, alongside the existing media, window, timeline, importer and source-protection checks. This release cleanup changes documentation, version metadata and packaging only.

The final full confirmation run passed in 156.9 seconds: 175 test cases, with 170 passed, five opt-in network checks skipped and zero failures. It included the supplied 4K AV1 source. Plist validity, shell syntax, local documentation links, media capabilities and whitespace checks also passed.

The initial full run executed 175 tests, with five opt-in network checks skipped and one timing assertion failing. On the supplied 3840×2160, 60 fps AV1/Opus WebM, the minimum loop-head enqueue lead was 49.2 ms against a strict requirement above 50 ms. The same test confirmed continuous video timestamps, sample-contiguous audio, no layer flush at the seam and no transport pauses. It passed on an isolated rerun. The threshold was left unchanged; loop timing remains sensitive to machine load.

The separate loopback TLS check passed. It confirms that the shipped FFmpeg rejects an untrusted self-signed peer without extra verification flags and without changing system trust.

Commands and local evidence:

```sh
bash scripts/make-fixtures.sh
bash scripts/make-waveform-fixtures.sh
bash scripts/make-subtitle-fixtures.sh
CLIPPER_SAMPLE='/absolute/path/to/4k-av1.webm' bash scripts/test.sh
CLIPPER_SAMPLE='/absolute/path/to/4k-av1.webm' bash scripts/test.sh --skip-build --filter LoopAuditionTests.testReal4KSelectionLoopsContinuouslyWhenProvided
CLIPPER_RANGE_NETWORK_TEST=1 bash scripts/test.sh --skip-build --filter URLRangeTests.testNetworkBuildRejectsBadCertificatesByDefault
```

Logs for this pass are `.build/release-0.5.0-tests.log`, `.build/release-0.5.0-loop-recheck.log`, `.build/release-0.5.0-tests-recheck.log` and `.build/release-0.5.0-tls.log`. They are local build outputs rather than distributed source files. The supplied real-source check uses `FINAL LIFE： Episode 2 - BIG BUSINESS [shJPWM_mNcQ].webm` from the user's home directory and leaves it untouched.

## Covered behavior

- Real decoding and frame selection across H.264 MP4, VFR MKV, VP9/AV1 WebM, legacy AVI, B-frames, nonzero start times and rotation. Export checks compare first/last frame identity, counts and timing after lossy hardware encoding.
- Hardware H.264/HEVC, crop geometry, no upscaling, HDR color tags and SDR conversion; original source and symlink/hard-link protection; confirmed output replacement, cancellation and failure preservation.
- Warm transport resume, cached frame/audio continuity, rapid steps/marks, encoded comparison alignment, divider ownership, continuous loop scheduling and cut audition.
- Gesture-grouped undo/redo, native text undo, source-history resets and integrated preference/subtitle/waveform updates.
- File copy/drag items on isolated pasteboards, completed-output lifetime, remembered export settings, bounded waveform peaks and selected-track changes.
- SRT/WebVTT/ASS/SSA parsing, authored/override styling, imported snapshot lifetime, subtitle geometry, HDR policy, real cue timing and rendered hardware exports, including verified URL-range original-time mapping.
- Import argument construction, tool recovery, workspace leases/cleanup, rough-range verification, original/local timestamp conversion and explicit full-download fallback.
- Native window sizing, centering geometry and timeline scroll layout.

## Checks still requiring hands-on use

Try the native app with the files and destination apps used day to day. Automated model/layer checks do not measure physical display/audio latency, subjective AV1 smoothness, trackpad pinch, modal Save As interaction or whether another app accepts a pasted/dragged file. Subtitle style popovers, font fallback, complex authored ASS scripts and text-field undo should also receive a manual pass.

The main run skips managed-tool installation, public-site imports and real yt-dlp loopback/range tests unless their opt-in variables are set. The TLS certificate check was run separately. Earlier branch handoffs contain their own network-test evidence, but it is not a fresh public-site check for this release.

macOS 14 is the deployment target, not a claim of runtime testing on an older Mac. Native glass has an availability-gated fallback. Current builds are ad-hoc signed; Developer ID signing and notarization remain follow-ups for easier sharing.

## Product limits

AV1 playback on M1 uses software decoding. Very demanding sources can drop playback frames; a distant exact seek still decodes from a keyframe. Cached nearby steps and warm resume reduce repeat work. Renderer timing tests do not establish perceived A/V sync over a long viewing session.

Dolby Vision dynamic-metadata preservation and unusual AVI timestamp layouts need broader real-world coverage. HDR transfer/primaries and explicit SDR conversion have synthetic test coverage. HDR subtitle burn-in requires SDR conversion; bitmap subtitles and WebVTT CSS/positioning are unsupported. Subtitle source/style changes are outside undo history.

URL ranges depend on server/index behavior and may transfer most of the original. Ranged imports omit embedded subtitles and use millisecond container timestamps. Live streams, DRM, playlists, browser-cookie authentication and audio-only imports are unsupported. See the [usage guide](guide.md) for details.

## Release artifacts

The packager requires a clean commit, stages and verifies an ad-hoc signed self-contained app, and creates versioned app/source ZIPs with SHA-256 checksums. The source receipt identifies the exact commit. Dependency sources, license texts, build recipes, subtitle checksums and the TLS patch accompany the release.

Source control retains earlier validation reports and completed per-feature handoffs at `e9d2c5d`. The current build and verification commands are in [development.md](development.md).
