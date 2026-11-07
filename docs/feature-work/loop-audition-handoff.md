# Selection loop and cut audition review

Implemented on `feature/loop-audition`, based on planning commit `3f1c966` and Clipper 0.4.3. No sibling feature branches are required.

## Try it

Run `dist/Clipper Loop Audition.app`, open a video and set the amber selection edges. Enable the repeat button or Playback > Loop Selection with Cmd-L, then press Space. Toggling Loop while paused starts nothing and prepares the loop head in the background. Turning it off during playback stops at the next safely scheduled boundary. Re-enabling it after a stop has been committed restarts the loop with a visible rewind gap; a warm-paused restart rebuilds the queue if future audio had already been flushed. Space pauses even while a wrap is preparing.

Use the adjacent cut-audition button or Playback > Audition Cut with Shift-Cmd-L. It starts at the source frame containing one second before the exclusive out boundary and plays once, then holds the last included frame. A selection shorter than one second plays in full. Audition temporarily overrides Loop and leaves the markers unchanged.

In Original, Loop repeats the whole selection. In Output and Compare, it repeats the available encoded sample. Audition stays in the encoded mode if that sample reaches the selected out point. Otherwise, it switches to Original and auditions the actual cut. Render a new Preview 5 s near the out point to audition the encoded cut.

Pause, scrub, frame-step, change a marker, change preview modes, start a render/import, replace the source, or close it to interrupt transport. Mute, crop and codec changes keep Original playback running. Settings that invalidate an encoded preview return to paused Original; changing audio tracks reopens the source decoder and pauses. Marker edits keep Loop enabled but leave playback paused. Replacing or closing the source resets Loop.

## Implementation and review

Original now keeps one continuous render clock across selection wraps. A second decoder prepares the next pass on a separate utility queue with its own cancellation token. At the cut, the pump swaps decoders and gives the old one the whole next pass to seek and decode preroll. Sample buffers receive shallow timing copies using an integer pass count and a rational source-time-base period. PCM audio uses a 48 kHz integer grid and clips at the pass boundary, with no crossfade. Playback preparation includes at least 80 ms of Opus decoder preroll; frame-editing seeks retain their fast path. Complete short passes can replay from a cache capped at 128 MiB. Only the active decoder retains the existing raw-frame cache.

Pause retains the continuous timeline and queued buffers for warm resume; the source playhead and frame steps use original frame timestamps. Explicit seeks, marker changes, source replacement and close cancel or replace preparation. A render-clock boundary observer is used only for a committed stop or fallback, not for a successful wrap. Encoded Output/Compare loops still use their existing AVPlayer seek/end path. This follow-up improves Original, with no preview transcode or pixel changes. No new media dependencies or configure options.

Claude consulted on the plan and reviewed the code. The review found delayed B-frames after interleaved audio, single-frame loop clock reuse, startup failure flags, unnecessary settings interruptions, and disabled-menu consistency. These findings were fixed, with regression checks for final B-frame delivery per pass and one-frame looping. The implementation adopts Playback-owned cancellation, exclusive audio/video cutoff, short-range priming and explicit cache limitations. Claude subsequently resumed the follow-up review and approved all five fixes with no remaining substantive findings. The recheck was read-only; test results come from the local hardware checks below.

For the continuous-loop follow-up, Claude agreed with the two-decoder design and reviewed its implementation. The review found cancellation treated as EOF, stale prepared-lane availability after cancellation, re-enable stop state, unnecessary Opus preroll for edit seeks, a stop boundary behind queued frames, and a missing finite-time guard. All were fixed. Cancellation and lane scheduling now share generation validation; prepared lanes are removed synchronously on cancel; re-enable restores flushed playback through a fresh queue; only playback preparation adds audio preroll; stop boundaries use the pump's rational pass grid. The real-source test also caught a 1 ms truncation error when building that grid; periods now round to the nearest source tick before rational multiplication, and the render scheduling lead is 0.4 seconds. These were small direct fixes validated with the new regression cases, without another review round.

## Validation

Eighteen focused tests pass when the real-source check is enabled, comprising fourteen feature tests and four adjacent media regressions. See `.build/continuous-loop-reviewed-tests.log` for hardware test results. The original regression test failed with four pauses in 0.8 seconds before this follow-up. It now requires an uninterrupted renderer clock. Additional checks cover 100 single-frame passes, warm resume, contiguous PCM timestamps, renderer rate and display flushes, rapid off/on while playing and paused, and repeated cancellation/source replacement. Run with native VideoToolbox, IOSurface and renderer access available, outside a restrictive shell sandbox:

```sh
mkdir -p .build/tmp
TMPDIR="$PWD/.build/tmp" NSUnbufferedIO=YES CLIPPER_SAMPLE="/path/to/the/4K-source.webm" bash scripts/test.sh -c release --filter 'LoopAuditionTests|MediaTests.testPlayPauseRetainsImageAndResumesWithoutSeeking|MediaTests.testEncodedCompareStepsKeepSourceAndOutputFramesAligned|MediaTests.testRapidStepsAndMarkWaitForTheRequestedFrame|MediaTests.testCachedFrameSteppingUsesDecodedVFRBoundaries'
```

The feature tests cover short CFR and VFR selections, single-frame audition and loops, repeat passes, exclusive video and PCM audio cutoffs, image retention, audition overriding Loop, unchanged markers, rapid cancellation, pause during wrap, source replacement, editing/import interruption, bounded Output/Compare loops and fallback to Original. Adjacent checks cover warm pause/resume, exact VFR frame stepping and Compare/marker queues. The optional real-source check uses the 493.257 to 499.890 second range from the reported 3840×2160 60 fps AV1/Opus source. It checks two complete 6.633-second wraps, no transport pauses or display flushes, a steady renderer rate, first-frame presentation times at each seam, more than 50 ms of head scheduling lead, and PCM continuity within one sample. The measured clock advanced about 13.7 seconds over the check, with zero pauses. Full codec/export and broad device performance suites remain outside this focused check.

Sandboxed test attempts failed during native renderer/IOSurface startup, including the unchanged baseline. Those attempts do not validate transport behavior. Hardware-enabled checks are the relevant results.

## Limits and integration

Continuous Original looping requires the spare decoder to prepare within a pass. Very short loops that do not fit the pass cache, slow storage, or a source that saturates decoding can still miss that deadline. In that case, or after a late re-enable at an already committed stop, playback holds the last image, uses the seek/restart fallback, and shows "Rewind gap" beside the repeat button. That warning means the pause is playback overhead and must not be used to judge a seamless cut. Memory stays bounded by the pass cache, one active raw-frame cache, two decoder pools and the normal renderer queue; it does not grow with the selection duration. Output/Compare still seek at encoded sample wraps.

VFR audition can start slightly more than one second before the cut because it begins at the containing frame's start. Stop callbacks may run late under main-thread load, while queued audio/video still respect the scheduled cut. Disabling Loop flushes future audio and stops at a boundary with a small safety lead. If Loop is re-enabled after that stop was committed, playback restarts honestly with a rewind gap rather than silently stopping. Warm resume rebuilds the queue when necessary to restore flushed audio.

Likely integration overlap is in `Editor.swift`, `Playback.swift`, the timeline transport controls and the Playback menu, particularly with undo/redo and waveform work. No branches were merged and nothing was pushed. Main gained `docs/feature-work/SCHEDULE.md` and `kickoff-manifest.json` after this branch was created. This feature does not delete those files; retain them during integration.

## Rebuild and distribute

After committing, run `bash scripts/package-loop-audition.sh`. This creates a distinct ad-hoc signed Apple Silicon app for macOS 14+, bundle identifier `app.clipper.review.loop-audition`, and removes Finder document-handler registration from the staged bundle. Production version numbers remain unchanged.

Distribute `dist/Clipper-Loop-Audition-macOS-arm64.zip` together with `dist/Clipper-Loop-Audition-Sources.zip`. The latter contains the exact Git source archive, commit receipt, dependency source archives, licenses, configure receipt and build recipes. Unchanged media/vendor inputs were reused read-only from the shared cache; Swift scratch, fixtures, test exports and review artifacts belong to this worktree. The review app contains its media tools and dylibs and does not need the shared cache at runtime. Gatekeeper may require local approval because the app is ad-hoc signed.
