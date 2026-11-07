# Undo and redo review candidate

Implemented in `feature/undo-redo`, based on planning commit `3f1c966` and Clipper 0.4.3. The exact packaged commit is in `dist/Clipper-Undo-Redo-Sources/BUILD.txt` and inside the app at `Contents/Resources/Review-Build.txt`.

This is a working candidate with Claude code review still outstanding. Claude agreed to the implementation plan and its amendments were adopted. The subsequent code-review run reached Claude's five-hour usage limit before returning findings. It explicitly reported a reset at 08:20 Europe/Warsaw on 7 November 2026. A continuation in this same thread is scheduled for 08:25 to obtain a new Claude review, resolve findings, retest, commit and rebuild matching packages. No provider was substituted.

## Try it

Open `dist/Clipper Undo Redo Review.app`, or unzip `dist/Clipper-Undo-Redo-Review-macOS-arm64.zip`. It has bundle ID `app.clipper.video.review.undo-redo` and no Finder document associations. The production version stays 0.4.3. This is an ad-hoc signed Apple Silicon build for macOS 14 or newer.

1. Open a video in the review app. Drag a trim edge, choose a crop preset, move or resize the crop, change quality or resolution, then toggle audio.
2. Press Cmd-Z repeatedly, then Shift-Cmd-Z. The Edit menu names the next action. Each completed timeline, crop or quality-slider gesture is one entry. I/O marks, boundary nudges and submitted timestamps are separate entries.
3. In Custom crop, enter a ratio and press Return or leave the field to commit. Timestamps commit on Return. While editing text, Cmd-Z and Shift-Cmd-Z use native text undo. After a submitted timestamp or ratio, focus leaves the field so the next Cmd-Z operates on the edit.
4. Undo an edit, then make another edit. Redo clears. Render a sample preview, then undo or redo an edit. The encoded sample is discarded.
5. Open another file, reopen the same file, or close the video. Old edit history clears. Opening and cancelling the URL importer preserves history.

## Validation

22 focused checks passed with zero failures: 15 new undo/redo checks, two window-layout checks, timeline scrolling, and four existing trim, comparison-preview and output-replacement regressions. They use real decode, hardware encode and private fixture/output files. Native text undo is checked through an offscreen test window, without the general clipboard or preferences. Audio-track undo also tests an unfinished decoder reopen.

Reproduce after preparing fixtures with `scripts/make-fixtures.sh` or copying unchanged baseline fixtures into this worktree's `.build/fixtures`:

```sh
bash scripts/test.sh --filter 'UndoRedoTests|TimelineTests|EditorWindowTests|MediaTests/testRapidStepsAndMarkWaitForTheRequestedFrame|MediaTests/testRapidBoundaryNudgesCommitEveryFrameAndRejectInvalidMarks|MediaTests/testEncodedCompareStepsKeepSourceAndOutputFramesAligned|MediaTests/testConfirmedExportReplacesOnlyAfterSuccessAndCancellationKeepsOutput'
```

Use a shell with access to macOS media/window services. In the agent sandbox, both new and existing XCTest media cases aborted inside `XCTSwiftErrorObservation` before assertions with `freed pointer was not the last allocation`. The unchanged async tests and new tests pass with the required service access. No test-runner workaround remains in the code. Detailed evidence is in `.build/undo-validation.log`.

Package from a clean committed tree with `bash scripts/package-undo-redo-review.sh`. The script makes a distinct staged review bundle, verifies its signatures, and packages the exact source commit, FFmpeg/dav1d/zimg source archives, build configuration, recipes, notices and receipts. Distribute the app and source ZIPs together. Checksums are in `dist/Clipper-Undo-Redo-SHA256.txt`.

## Behavior and limits

The editor owns a native UndoManager with explicit groups and a 200-entry limit. It remains separate from the window's text undo manager. Full snapshots include both trim frames and normalized settings. Restoring a snapshot preserves the exact crop position, updates audio and playback bounds, seeks the affected boundary and invalidates encoded previews.

Edit history is disabled while loading, rendering/exporting, importing, or holding an edit gesture. Export finalizes any active gesture before capturing the export settings. A completed timeline drag waits for its final frame decode. If another action supersedes a pending trim, the model commits the frames already resolved and rejects stale callbacks. Unresolved intermediate frames do not become edits. Source replacement and close clear all history, including a reopen of the same URL.

This pass does not claim a manual end-to-end accessibility or appearance audit across macOS versions. Automated integration checks cover the model, native text routing and nearby window behavior. Claude's final code review remains required before calling the whole assignment complete. No new media dependency, full hardware regression sweep, push, merge or PR is part of this candidate.

Likely integration overlap with the other feature branches is in Editor.swift, EditorView.swift, Viewer.swift, Timeline.swift and ClipperApp.swift. Settings controls must keep using atomic `updateSettings`; restoring history must not trigger crop re-normalization. The shared `.build/media` and `.build/vendor` inputs were reused read-only; Swift build/module caches, fixtures and all artifacts remain private to this worktree.
