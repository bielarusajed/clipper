# Validation and known limits

## 0.5.5 concentric islands

The inspector and timeline use Apple's `ConcentricRectangle` with uniform corners and an 8-point minimum. The native window outline is unchanged. Reduced Transparency uses the same shape with an opaque background; macOS 14/15 retain a fixed 8-point fallback. The empty-state icon keeps its separate fixed shape.

A public `GeometryProxy.concentricCornerRadii` probe in a full-content native window with a unified toolbar measured 8-point radii at the sidebar's leading corners and the timeline's bottom-trailing corner, at the existing 8-point inset. Computer-use inspection verified the loaded editor, full screen, and return to windowed mode. The five native window checks are recorded in `.build/concentric-window-tests.log`; the build log is `.build/concentric-build.log`. This visual-only change does not address the existing playback timing failures recorded below.

## 0.5.4 native control appearance

Archived binaries establish that the SDK stamp changed from 27.2 to 14.0 when SwiftPM switched to its `swiftbuild` engine, before the Compact window work. Packaged and unbundled binaries agree, ruling out signing and library packaging. Restoring the `native` engine produces `minos 14.0 / sdk 27.2` with the same window code. The new packaging guard rejects the actual regressed binary and accepts the rebuilt binary, including equivalent version spellings such as 27.2.0.

Five native window tests pass, including AppKit ownership, shared hover tracking and measured filename clearance. Computer-use screenshots show the larger, shaded native controls in both the empty and loaded-video layouts; these captures show inactive gray controls, so colored hover and tiling were not visually reverified. The user confirmed correct hover before this build-only correction. Claude reviewed the diagnosis and build changes. Logs are `.build/sdk-appearance-build.log` and `.build/sdk-appearance-window-tests.log`.

The integrated run with the supplied 4K AV1 file executed 180 tests in 166.7 seconds, with five skipped and three failures. All failures are playback-clock thresholds in `testHundredSingleFramePassesAndWarmResumeKeepTimeline`, `testLoopClockNeverStopsOrRewindsAcrossWraps` and `testSubtitleCueReturnsAfterContinuousLoopWraps`. Rerunning these three against the untouched pre-change Swift Build test bundle also fails all three. They remain unresolved; the suite is not fully green. Logs are `.build/sdk-appearance-full-tests.log` and `.build/sdk-appearance-baseline-loop-tests.log`. The packaging guard also rejects a deployment target inconsistent with the plist's minimum system version.

## 0.5.3 preview compositing workaround

The user reproduced black rectangular occlusions without screen recording, and reported that they stopped while recording. Migrating to the background-safe video renderer and removing the outer SwiftUI mask did not resolve the symptom. A subsequent same-app test toggled source-viewport group opacity between 1 and 0.99 without screen recording. The user marked three glitches at opacity 1 and reported none with 0.99 blending enabled.

At all three markers, the source geometry covered the viewport, the output layer was hidden with no wipe mask, and the renderer was ready with no error or flush requirement. Sampled displayed-buffer brightness did not show a black right-hand region. These observations support a presentation/compositing issue; they do not establish an undocumented macOS direct-presentation mechanism as the cause.

Production now enables group opacity at 0.99 on the source viewport. This slightly dims the source preview, including its subtitle overlay, but does not change decoded or exported pixels. Output preview remains at full opacity. The native root layer clips both video layers to an eight-point corner radius, alongside the restored SwiftUI rounded clip and border. The square corners in the diagnostic app came from intentionally removing its outer mask. The normal app contains no diagnostic menu or logging.

A regression for persistent blending and native rounded clipping failed before the change and passed afterward. Three focused tests passed, covering the renderer registration, crop/comparison geometry, source-layer ownership, and blending/clipping across Original, Compare and Output modes and resizing. The earlier renderer migration ran 44 media/loop tests with four optional source checks skipped and no failures; three additional startup, chase and continuous-loop checks passed using the reported 4K AV1 source. The successful blend experiment is user-observed; the final blend-plus-rounded-corners build still needs confirmation in normal use.

Playback uses the display layer's `AVSampleBufferVideoRenderer` for synchronizer registration and all enqueue, flush, readiness and status operations, following the SDK's documented background-enqueue path available on macOS 14. A `VideoOutput` adapter preserves real-renderer transport test coverage. The native view assigns its root layer before enabling layer hosting. Timing flags, decoder selection and glass composition are unchanged.

Earlier capture-based negative tests cannot establish that the flicker is absent: screen recording appears to suppress it. The isolated test apps and detailed investigation report remain in ignored build directories for reference.

## 0.5.2 Compact window

The integrated run passed 177 tests, with five opt-in checks skipped and zero failures, in 188.1 seconds. It included the supplied 4K AV1 WebM. After the final review fixes, seven focused window, timeline and comparison-layer tests passed. Logs are `.build/compact-full-tests.log` and `.build/compact-final-window-tests.log`.

An offscreen AppKit repro caught the misplaced native group-hover region when controls were reparented or manually moved. Production leaves the controls untouched in a real unified toolbar. The regression now uses the actual SwiftUI editor and checks native ownership, shared tracking coverage for all three buttons, filename clearance, vertical alignment, toolbar lifetime and repeated source changes. Window tests also cover full-frame portrait/landscape sizing and screen limits. A separate native probe established that `contentMaxSize` avoids the extra toolbar offset returned by `maxSize` on this system.

Claude reviewed the production change. The final fixes remove toolbar visibility/customization commands, disallow window tabs, accept the first mouse click in the filename drag region, and measure geometry after native layout. The discarded Chrome Lab app and archives were retired into ignored build folders; its source history remains on the prototype branch.

The self-contained app passed signature verification. Onscreen verification could not be completed: computer use returned `cgWindowNotFound` for both the installed and rebuilt Clipper. A process sample showed the rebuilt app idle in its normal AppKit event loop, not stuck in startup code. Native hover glyph appearance, green-button tiling, focus changes and full-screen round-trips still need a visual pass. The automated geometry checks do not establish those visual results.

## 0.5.1 window chrome

The native window probe confirmed that blur was enabled, Reduce Transparency was off, and the window background was clear. Its title bar had reverted to an opaque background and visible title after initial setup. The window hook now reapplies transparent, separator-free chrome after SwiftUI updates and deferred sizing. It only changes properties that differ, and keeps the system appearance.

The regression failed before the fix. It now covers a chrome reset both with unchanged source metadata and when opening a source. Five focused tests passed, including adaptive window sizing, timeline scrolling and persistent comparison-layer geometry. Logs are `.build/window-appearance-red.log` and `.build/window-appearance-green.log`. Temporary appearance probes were removed. Media and glass rendering code are unchanged from 0.5.0.

## 0.5.0 integration

Release validation uses the merged application on an Apple M1 Pro with macOS 27.0.1 and Xcode 27.2. All seven feature suites are integrated on main, alongside the existing media, window, timeline, importer and source-protection checks. This release cleanup changes documentation, version metadata and packaging only.

The final full confirmation run passed in 156.9 seconds: 175 test cases, with 170 passed, five opt-in network checks skipped and zero failures. It included the supplied 4K AV1 source. Plist validity, shell syntax, local documentation links, media capabilities and whitespace checks also passed.

The initial full run executed 175 tests, with five opt-in network checks skipped and one timing assertion failing. On the supplied 3840×2160, 60 fps AV1/Opus WebM, the minimum loop-head enqueue lead was 49.2 ms against a strict requirement above 50 ms. The same test confirmed continuous video timestamps, sample-contiguous audio, no layer flush at the seam and no transport pauses. It passed on an isolated rerun. The threshold was left unchanged; loop timing remains sensitive to machine load.

The separate loopback TLS check passed. It confirms that the shipped FFmpeg rejects an untrusted self-signed peer without extra verification flags and without changing system trust.

Open With cleanup was checked against the actual Launch Services database. Nine registered archived builds were removed, and all 40 existing backups were preserved as ordinary folders without an application suffix. macOS reports the retired copy as `public.folder`, not an application. A rebuild introduced no archived handler, kept the installed/current Clipper registrations and passed signature verification. The cleanup also passed a second, idle run.

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
