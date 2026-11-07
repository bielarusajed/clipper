# Undo and redo review candidate

Implemented in `feature/undo-redo`, based on planning commit `3f1c966` and Clipper 0.4.3. The exact packaged commit is in `dist/Clipper-Undo-Redo-Sources/BUILD.txt` and inside the app at `Contents/Resources/Review-Build.txt`.

Claude completed the final review of `c6be660` on 7 November 2026 and agreed that the first-version candidate was ready, with no blocking findings. All blocking findings from the earlier review of `10800fc` were resolved. Claude also verified the matching artifacts. The final small cleanups gate audio-track selection during decoding, narrow menu updates to seeking/importer-busy changes, and add a focused regression check. No further review round was required for those changes. No provider was substituted, and the completed continuation schedule is disabled.

## Try it

Open `dist/Clipper Undo Redo Review.app`, or unzip `dist/Clipper-Undo-Redo-Review-macOS-arm64.zip`. It has bundle ID `app.clipper.video.review.undo-redo` and no Finder document associations. The production version stays 0.4.3. This is an ad-hoc signed Apple Silicon build for macOS 14 or newer.

1. Open a video in the review app. Drag a trim edge, choose a crop preset, move or resize the crop, change quality or resolution, then toggle audio.
2. Press Cmd-Z repeatedly, then Shift-Cmd-Z. The Edit menu names the next action. Each completed timeline, crop or quality-slider gesture is one entry. I/O marks, boundary nudges and submitted timestamps are separate entries.
3. In Custom crop, enter a ratio and press Return or leave the field to commit. Timestamps commit on Return. While editing text, Cmd-Z and Shift-Cmd-Z use native text undo. After a submitted timestamp or ratio, focus leaves the field so the next Cmd-Z operates on the edit.
4. Undo an edit, then make another edit. Redo clears. Render a sample preview, then undo or redo an edit. The encoded sample is discarded.
5. Open another file, reopen the same file, or close the video. Old edit history clears. Opening and cancelling the URL importer preserves history.

## Validation

27 focused checks passed with zero failures: 20 new undo/redo checks, two window-layout checks, timeline scrolling, and four existing trim, comparison-preview and output-replacement regressions. They use real decode, hardware encode and private fixture/output files. Native text undo is checked through an offscreen test window, without the general clipboard or preferences. Audio-track history waits for decoder reopening, then restores the selected track correctly. Pending trim marks survive a following frame step, play request or quality change. Audio-track selection is disabled while decoding, with the same guard in the model, so a decoder reopen cannot discard a pending mark. A new gesture cannot merge into a still-decoding timestamp mark.

Reproduce after preparing fixtures with `scripts/make-fixtures.sh` or copying unchanged baseline fixtures into this worktree's `.build/fixtures`:

```sh
bash scripts/test.sh --filter 'UndoRedoTests|TimelineTests|EditorWindowTests|MediaTests/testRapidStepsAndMarkWaitForTheRequestedFrame|MediaTests/testRapidBoundaryNudgesCommitEveryFrameAndRejectInvalidMarks|MediaTests/testEncodedCompareStepsKeepSourceAndOutputFramesAligned|MediaTests/testConfirmedExportReplacesOnlyAfterSuccessAndCancellationKeepsOutput'
```

Use a shell with access to macOS media/window services. In the agent sandbox, both new and existing XCTest media cases aborted inside `XCTSwiftErrorObservation` before assertions with `freed pointer was not the last allocation`. The unchanged async tests and new tests pass outside the restricted sandbox in this same worktree. Claude also reproduced a passing clean build. The exact cause of the restricted-run abort was not confirmed; no app-code failure was demonstrated. No test-runner workaround remains in the code. Detailed evidence is in `.build/undo-validation.log`.

Package from a clean committed tree with `bash scripts/package-undo-redo-review.sh`. The script makes a distinct staged review bundle, verifies its signatures, and packages the exact source commit, FFmpeg/dav1d/zimg source archives, build configuration, recipes, notices and receipts. Distribute the app and source ZIPs together. Checksums are in `dist/Clipper-Undo-Redo-SHA256.txt`.

## Behavior and limits

The editor owns a native UndoManager with explicit groups and a 200-entry limit. It remains separate from the window's text undo manager. Full snapshots include both trim frames and normalized settings. Restoring a snapshot preserves the exact crop position, updates audio and playback bounds, seeks the affected boundary and invalidates encoded previews.

Edit history is disabled while loading, rendering/exporting, importing, decoding a requested frame, stepping an encoded preview, or holding an edit gesture. Export finalizes any active gesture before capturing the export settings. A completed timeline drag waits for its final frame decode. If another action supersedes a pending trim, the model commits the frames already resolved and rejects stale callbacks. Unresolved intermediate frames do not become edits. Undo is disabled until a pending discrete mark or final drag frame resolves; the next Undo applies to the completed edit. Source replacement and close clear all history, including a reopen of the same URL.

This pass does not claim a manual end-to-end accessibility or appearance audit across macOS versions. Computer Use failed to locate the separate review app window with `cgWindowNotFound`, so the live GUI smoke check could not be completed. Automated integration checks cover the model, actual-responder menu policy, native text routing and nearby window behavior. Claude accepted these GUI verification limits for a first-version review build.

Two lower-risk points remain for manual GUI verification: the ordering of SwiftUI's final quality-slider callback after a click/drag, and transport-key interruption during a held crop/quality gesture. Transport commands currently settle the active gesture; remaining updates from that gesture are ignored until a new drag. Starting a gesture while decoding is rejected, and rejected quality gestures cannot fall back to one entry per tick. Native text undo should also be tried in timestamp, ratio and URL fields in the review app. An unsubmitted timestamp draft resets on focus loss. Claude accepted these documented behavior limits and found no remaining blocker. No new media dependency, full hardware regression sweep, push, merge or PR is part of this candidate.

Likely integration overlap with the other feature branches is in Editor.swift, EditorView.swift, Viewer.swift, Timeline.swift and ClipperApp.swift. Settings controls must keep using atomic `updateSettings`; restoring history must not trigger crop re-normalization. The shared `.build/media` and `.build/vendor` inputs were reused read-only; Swift build/module caches, fixtures and all artifacts remain private to this worktree.

## PR conflict resolution

PR #6 now incorporates `origin/main` at `ef73cab`, including waveform, export handoff, export preferences, URL-range imports and subtitles. The conflict resolution preserves private atomic edit commits and exact crop restoration. Both edit commits and undo/redo refresh the waveform and rebuild subtitle geometry. Codec and quality controls retain remembered choices, including undo/redo, while forced HDR normalization never overwrites the SDR codec preference. Initial settings still load without undo entries. Displayed timestamps retain verified original-video offsets and submit local frame times.

Existing feature tests now use the atomic edit API. Undo tests use isolated preferences rather than the user's defaults. Three new integration checks cover remembered codec/quality through undo/redo, HDR conversion undo preserving the SDR preference, and subtitle geometry through crop undo/redo.

The merge regression run passed 135 tests with zero failures; four optional network checks were skipped. It covers all integrated feature suites, native text and window/timeline behavior, source protection, confirmed replacement and HDR conversion. Evidence is in `.build/undo-merge-tests.log`. The media capability check also passed.

```sh
bash scripts/test.sh --filter 'UndoRedoTests|SubtitleTests|WaveformTests|ExportPreferencesTests|ExportHandoffTests|URLRangeTests|URLImportTests|ImportWorkspaceTests|ManagedImportToolsTests|PasteImportTests|TimelineTests|EditorWindowTests|MediaTests.testExportProtectsSourceThroughSymlinksAndHardLinks|MediaTests.testPublishingDoesNotReplaceWithoutConsentOrWhenNewFileIsMissing|MediaTests.testConfirmedExportReplacesOnlyAfterSuccessAndCancellationKeepsOutput|MediaTests.testHDRPreserveAndSDRConversion'
bash scripts/check-media.sh
```

Media/vendor inputs were copied privately from the already-built subtitle/TLS stack without modifying another worktree. The updated review source package includes the subtitle dependency source archives, build/checksum recipes, certificate-verification patch and hash receipt alongside the existing sources. Rebuild the matching review ZIPs with the packaging command above. The source receipt identifies the exact merged commit.
