# Selection loop and cut audition review

Implemented on `feature/loop-audition`, based on planning commit `3f1c966` and Clipper 0.4.3. No sibling feature branches are required.

## Try it

Run `dist/Clipper Loop Audition.app`, open a video and set the amber selection edges. Enable the repeat button or Playback > Loop Selection with Cmd-L, then press Space. Toggling Loop while paused starts nothing; toggling it off during playback finishes the current pass. Space pauses even while a wrap is preparing.

Use the adjacent cut-audition button or Playback > Audition Cut with Shift-Cmd-L. It starts at the source frame containing one second before the exclusive out boundary and plays once, then holds the last included frame. A selection shorter than one second plays in full. Audition temporarily overrides Loop and leaves the markers unchanged.

In Original, Loop repeats the whole selection. In Output and Compare, it repeats the available encoded sample. Audition stays in the encoded mode if that sample reaches the selected out point. Otherwise, it switches to Original and auditions the actual cut. Render a new Preview 5 s near the out point to audition the encoded cut.

Pause, scrub, frame-step, change a marker, change preview modes, start a render/import, replace the source, or close it to interrupt transport. Mute, crop and codec changes keep Original playback running. Settings that invalidate an encoded preview return to paused Original; changing audio tracks reopens the source decoder and pauses. Marker edits keep Loop enabled but leave playback paused. Replacing or closing the source resets Loop.

## Implementation and review

Playback owns a run identifier that survives internal wrap seeks and becomes invalid on public transport interruptions. A separate requested-playing state keeps the pause control active during preparation. The decoder excludes frames at the out boundary and clips the final PCM audio buffer, matching the export's hard cut. A render-clock boundary observer triggers wrap or final-frame hold. Encoded loops use the existing AVPlayer end notification and Compare synchronization. No new media dependencies or configure options.

Claude consulted on the plan and reviewed the code. The review found delayed B-frames after interleaved audio, single-frame loop clock reuse, startup failure flags, unnecessary settings interruptions, and disabled-menu consistency. These findings were fixed, with regression checks for final B-frame delivery per pass and one-frame looping. The implementation adopts Playback-owned cancellation, exclusive audio/video cutoff, short-range priming and explicit cache limitations. Claude subsequently resumed the follow-up review and approved all five fixes with no remaining substantive findings. The recheck was read-only; test results come from the local hardware checks below.

## Validation

Thirteen focused tests pass, comprising nine feature tests and four adjacent media regressions. See `.build/focused-review-fixes-tests.log` for hardware test results. Run with native VideoToolbox, IOSurface and renderer access available, outside a restrictive shell sandbox:

```sh
mkdir -p .build/tmp
TMPDIR="$PWD/.build/tmp" NSUnbufferedIO=YES bash scripts/test.sh -c release --filter 'LoopAuditionTests|MediaTests.testPlayPauseRetainsImageAndResumesWithoutSeeking|MediaTests.testEncodedCompareStepsKeepSourceAndOutputFramesAligned|MediaTests.testRapidStepsAndMarkWaitForTheRequestedFrame|MediaTests.testCachedFrameSteppingUsesDecodedVFRBoundaries'
```

The feature tests cover short CFR and VFR selections, single-frame audition and loops, repeat passes, exclusive video and PCM audio cutoffs, image retention, audition overriding Loop, unchanged markers, rapid cancellation, pause during wrap, source replacement, editing/import interruption, bounded Output/Compare loops and fallback to Original. Adjacent checks cover warm pause/resume, exact VFR frame stepping and Compare/marker queues. Full codec/export and large 4K performance suites are outside this focused feature check.

Sandboxed test attempts failed during native renderer/IOSurface startup, including the unchanged baseline. Those attempts do not validate transport behavior. Hardware-enabled checks are the relevant results.

## Limits and integration

Loop restarts reuse the existing bounded decoded cache. A long or high-resolution selection can outgrow it and require a keyframe seek. The last image remains visible during that brief pause. This first version does not promise gapless audio or a seamless wrap. VFR audition can start slightly more than one second before the cut because it begins at the containing frame's start. The clock callback may run late under main-thread load; queued audio/video samples still stop at the exclusive cut.

Likely integration overlap is in `Editor.swift`, `Playback.swift`, the timeline transport controls and the Playback menu, particularly with undo/redo and waveform work. No branches were merged and nothing was pushed. Main gained `docs/feature-work/SCHEDULE.md` and `kickoff-manifest.json` after this branch was created. This feature does not delete those files; retain them during integration.

## Rebuild and distribute

After committing, run `bash scripts/package-loop-audition.sh`. This creates a distinct ad-hoc signed Apple Silicon app for macOS 14+, bundle identifier `app.clipper.review.loop-audition`, and removes Finder document-handler registration from the staged bundle. Production version numbers remain unchanged.

Distribute `dist/Clipper-Loop-Audition-macOS-arm64.zip` together with `dist/Clipper-Loop-Audition-Sources.zip`. The latter contains the exact Git source archive, commit receipt, dependency source archives, licenses, configure receipt and build recipes. Unchanged media/vendor inputs were reused read-only from the shared cache; Swift scratch, fixtures, test exports and review artifacts belong to this worktree. The review app contains its media tools and dylibs and does not need the shared cache at runtime. Gatekeeper may require local approval because the app is ad-hoc signed.
