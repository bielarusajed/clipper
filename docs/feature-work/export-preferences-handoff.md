# Remembered export preferences review

Implemented on `feature/export-preferences`, based on planning commit `3f1c966` and Clipper 0.4.3. The source ZIP's `REVIEW-COMMIT.txt` identifies the exact packaged commit.

Codec and quality choices survive source changes and app launches through native UserDefaults. HDR forces HEVC without changing the preferred SDR codec. Convert to SDR restores that preference. Only explicit codec and quality control actions write these settings. Trim, crop, resolution, audio and HDR conversion remain per-video.

Confirming Save As or an imported-source save dialog records its parent folder. Future Save As and imported-source save dialogs start there with a unique suggested filename. The initial fallback is Downloads, including Save As for local videos. An unavailable saved folder falls back to Downloads, then home if Downloads is also unavailable. Cancelling the dialog does not change the saved folder. Confirming a folder remembers it even if rendering later fails or is cancelled. Ordinary local Export Clip continues to create a unique file beside its source. Source protection and confirmed replacement remain in place.

## Try it

1. Unzip `dist/Clipper-Export-Preferences-macOS-arm64.zip` and open `Clipper Export Preferences.app`.
2. Open an SDR video, choose H.265 and a quality setting, then use the export folder button or Shift-Cmd-E to save in a folder of your choice.
3. Quit and reopen the review app. Open another video and check the codec, quality and Save As folder. Ordinary Export Clip on a local file should still save beside the source.
4. Select H.264 on an SDR video, then open HDR. It should use H.265. Convert to SDR should restore H.264. Opening SDR again should also restore H.264.

The review bundle uses `app.clipper.video.review.export-preferences`, so it has separate preferences from stable Clipper. It does not register Finder video document types. The app is ad-hoc signed, targets Apple Silicon and macOS 14+, and includes its media engine. No new dependencies or production version changes were introduced.

## Reproduce

From this worktree, with Xcode selected:

```sh
mkdir -p .build/tmp
TMPDIR="$PWD/.build/tmp" bash scripts/test.sh -c release --filter 'ExportPreferencesTests|MediaTests.testSaveAsAcceptsConfirmedExistingOutput|MediaTests.testExportProtectsSourceThroughSymlinksAndHardLinks|MediaTests.testPublishingDoesNotReplaceWithoutConsentOrWhenNewFileIsMissing|MediaTests.testConfirmedExportReplacesOnlyAfterSuccessAndCancellationKeepsOutput|MediaTests.testHDRPreserveAndSDRConversion|URLImportTests.testTemporarySourceDisposesOnCloseReplacementAndQuit|URLImportTests.testExportOutlivesDisposableSource'
bash scripts/package-export-preferences-review.sh
```

Native editor tests require WindowServer, IOSurface and VideoToolbox access. In the restricted execution sandbox, constructing the existing native editor can abort inside XCTest and hardware encoding reports error -12908. Run the focused tests with native media access. Tests use UUID-named UserDefaults suites and private fixtures/outputs. They do not change stable Clipper's preferences or the clipboard.

The private `.build/media`, `.build/vendor` and fixture inputs were copied unchanged from the baseline dependency cache. Swift scratch/module caches, test outputs and `dist` are private to this worktree. A clean source tree is required by the packaging recipe. Both the app ZIP and matching source ZIP must be distributed together; the latter includes the dependency source archives, licenses, configure receipt and review packaging script.

## Validation and limits

The release-mode focused suite passed all 15 tests with zero failures. It covers defaults, persistence through fresh preference/editor instances, invalid values, missing/read-only folders, real HDR-to-SDR source switches, per-video resets, remembered imported-source destinations, unique filenames, a real hardware one-click export, HDR and SDR rendering, disposable-source cleanup, source aliases, replacement and cancellation. The test output is in `.build/final-release-tests.log`.

Claude agreed with the implementation plan and approved the resulting code with no blocking findings. The review's small cleanup suggestions were applied to test teardown, documentation and packaging intermediates.

Native Save As interaction and quit/relaunch have a manual checklist above; automated checks exercise their preference logic and fresh editor/defaults instances rather than driving modal dialogs. Folder storage uses a path in this non-sandboxed app. Moving/renaming a folder causes fallback until the user confirms a new destination. No security-scoped bookmarks or session recovery are included.

Integration overlap is in `Editor.swift` source resets/export destinations and `EditorView.swift` video bindings, especially with undo/redo, export handoff and subtitles. Review those independently when integrating; no sibling branch was merged. The review packaging script is feature-specific.
