# Export handoff review

## Behavior

After a successful export, the glass footer shows a file icon, filename, Copy and Show in Finder. Drag the icon/name into another application to give it the exported file. AppKit supplies the real file URL and allows copy only outside Clipper. Copy writes that same URL with `NSPasteboard.writeObjects`, so receiving apps can read the actual file.

The last successful export stays selected after a failed/cancelled render or a preview. A later successful export replaces it. The row hides during rendering and clears when the source closes or changes. Clipboard entries and exported files remain intact after closing the source or quitting.

Every action checks the file afresh. The footer also refreshes on hover, activation and every two seconds while visible. Moved, removed, unreadable files and paths replaced by directories disable Copy, drag and Finder reveal. Files are not followed after a move. Restoring a regular readable file to the original path makes it available again. A confirmed replacement at the same path means existing clipboard entries refer to its new contents.

Exports cannot go inside the managed import root or the current disposable source directory. Validation compares ancestor directory identities, including symlink/case aliases, before rendering and again before publication. Default output for files opened directly from the managed area falls back to Downloads. No media dependencies changed.

## Try it

1. Open `dist/Clipper Export Handoff.app`. Open a local video, mark a short clip and export it. The review app has its own bundle identity and no Finder document-handler declarations.
2. Click Copy. In Finder, open an empty scratch folder and paste. Open the pasted clip and confirm it is the exported range. In a Mail draft or another app that accepts file attachments, paste and check that it attaches a video rather than text.
3. Drag the footer icon/name into an empty Finder folder on the same volume. Confirm both the exported original and the dropped copy exist. Try a draft attachment area or video editor's import area as well. Receiving applications decide whether they accept file drops/paste.
4. Make a second export. Copy/drag should now use that result. Cancel another render and render a preview; the last completed export should return. Save As over an existing output and confirm macOS replacement still applies.
5. Move or trash the latest export in Finder. Return to the review app; actions should disable with "File moved or removed". Re-export to recover.
6. Import a URL, export into a permanent folder, and copy the result. Close the source or quit. Verify the exported clip and any pasted copy still open.

Pasting the copied clip back into Clipper opens it as a new source, as with a file copied in Finder. Dragging within Clipper is disabled. Dragging out of an inactive review window works without first bringing it forward.

## Reproduce

All mutable caches, fixtures and outputs belong to this worktree. The unchanged `.build/media` and `.build/vendor` inputs may be read-only symlinks to the baseline dependency cache, with `media-configure.log` copied locally. Copy the baseline `cfr.mp4` fixture into this worktree's `.build/fixtures`.

```sh
bash scripts/test.sh --filter 'ExportHandoffTests|MediaTests/testConfirmedExportReplacesOnlyAfterSuccessAndCancellationKeepsOutput|MediaTests/testExportProtectsSource|MediaTests/testPublishingDoesNotReplace|URLImportTests/testExportOutlivesDisposableSource'
bash scripts/package-export-handoff.sh
```

The package command requires a clean commit. It builds the release app, changes only the staged bundle name/identifier, removes document associations, re-signs it ad hoc and produces app/source ZIPs with dependency source archives, exact build receipts and a source commit identifier. Distribute both ZIPs together. Production remains version 0.4.3.

## Validation and limits

Nine focused tests pass, including real hardware export/replacement/cancellation, preview isolation, pasteboard URL round-trip and readable bytes, copy-only drag policy, stale paths, managed directory aliases and source cleanup. Named pasteboards leave the general clipboard alone. macOS pasteboard service and VideoToolbox access are needed; restricted sandbox runs cannot exercise them.

Claude reviewed the full implementation and approved packaging with no blockers. The suggested inactive-window drag handling, symlink ancestor hardening, unchanged-availability suppression and preservation of imported video type declarations were applied. The packaging inputs are linked/copied read-only as documented; a release build and bundled binary dependency check succeeded.

AppKit's actual drag writer and operation mask are tested. Receiving-app paste/drop gestures still need the manual checks above. A file can disappear after an external app has received its URL. There is no persistent export history, file promise, share picker or tracking of renamed files. Finder reveal and Copy remain keyboard-accessible buttons.

Likely integration overlaps are the footer, editor export completion/close paths and export-destination validation. No sibling feature was merged.
