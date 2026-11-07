# Burned in subtitles review

This first version burns text subtitles into hardware-encoded video. It supports external SRT, WebVTT, ASS and SSA, plus eligible container tracks including mov_text. Subtitles start disabled. The review app is named **Clipper Subtitles**, has bundle ID `app.clipper.review.hardsubs`, and does not register Finder document handlers.

Open `dist/Clipper Subtitles.app`, open a video, and scroll to Subtitles in the inspector. Enable the switch, choose a container track or an external file, and use the textformat button for the anchored style popover. A single eligible track has no redundant picker. Containers without eligible tracks show the file chooser directly. Try Preview 5 s, Compare, then Export Clip. For a repeatable example, open `.build/fixtures/subtitles/two-tracks.mkv` and seek to 2.5 seconds.

ASS/SSA preserves authored styles and positioning by default. Preserved scripts render on the rotated source frame before cropping, so crops can cut off signs or dialogue. The common style uses final output coordinates and scales font size against the output's short edge. It offers font family, size, text and edge colors, outline or solid box, shadow, top/bottom placement and margins.

Override authored style applies the same common style to ASS/SSA dialogue. It removes positioning, movement, clips, transforms, animation, karaoke, colors and effects. It retains bold, italic, underline, strikeout and line breaks. It omits drawings, initially hidden placeholders, comments and exact duplicate dialogue. Use preserve mode for complex signs and typesetting.

External files are imported as snapshots independent of the active subtitle source. Switching between container tracks and External keeps the imported text even if the original file changes, moves or is deleted. Only an explicit Choose/Change import rereads the file. Clear, closing the video and replacing the video discard the snapshot. External cues are relative to the video's beginning. For a verified URL range import, they use original-video time, matching the editor's displayed timestamps. If verification disables the mapping, they use local section time. Container cues retain absolute timestamps; the renderer accounts for the video's origin separately. Trim, crop, codec and audio changes keep the selection. Closing or replacing the source clears it and releases managed files after in-flight readers finish. Common style preferences remain for the current app session.

HDR burn-in requires explicitly choosing Convert to SDR. Export rejects HDR burn-in without it. Source view still shows the original video's colors; encoded preview and export show the existing SDR tone mapping. Text uses the same prepared ASS file, fonts and libass renderer across source view, quality preview and export. Hardware video encoding and source-protection/confirmed-replacement behavior remain in force.

## Validation

Claude consulted on architecture and reviewed the implementation. Its four requested fixes were applied: forced SRT/WebVTT demuxers, checksum verification before unpacking, reuse of unchanged render assets, and correct normal/review source-ZIP names. Its color caveat was fixed by applying the decoder's BT.709 assumption to untagged HD video before subtitle blending. Its smaller idle-rendering and export-popover suggestions were also applied. A final Claude review found no blocking correctness or security problems. Its two further findings were fixed: automatic source/track changes do not extract while subtitles are disabled, and explicitly reimporting the same file invalidates the encoded preview even when the URL is unchanged. Explicit file imports still prepare snapshots while disabled, and changing a disabled track clears the old track asset. The optional repeated empty-layer write was removed. Small findings were resolved locally without another review cycle. PR #5 subsequently identified a snapshot reread on source switching. The imported text now has a separate lifetime from active rendering, with regression tests for all four external formats and explicit reimport/clear/reset behavior.

The focused suite passes 23 tests, including 20 subtitle tests and three source-protection/replacement regressions. It exercises actual SRT/VTT/ASS/SSA parsing/rendering, late cues, multiple/default tracks, extracted font attachments, embedded origin offsets, actual hardware export cue boundaries, cropped output vs live-renderer pixel parity, VFR, rotation, source offsets, HDR rejection and SDR output, saturated red on untagged HD, missing/unsupported external files, spoofed SRT rejection, asset reuse, enabling during catalog scanning, disabled source/track changes, explicit import while disabled, reloading changed text from the same path over a real encoded preview, snapshot retention across source switches after file edits/moves, clear/reset behavior, and managed cleanup. The broad baseline hardware suite was not repeated. Native UI inspection could not complete because Computer Use returned `cgWindowNotFound`; interactive popover appearance and playback smoothness need human review.

Reproduce locally:

```sh
bash scripts/make-subtitle-fixtures.sh
bash scripts/test.sh --filter 'SubtitleTests|MediaTests.testExportProtectsSourceThroughSymlinksAndHardLinks|MediaTests.testPublishingDoesNotReplaceWithoutConsentOrWhenNewFileIsMissing|MediaTests.testConfirmedExportReplacesOnlyAfterSuccessAndCancellationKeepsOutput'
CLIPPER_REVIEW_BUILD=1 bash scripts/package-release.sh
```

The rotation/VFR/HDR regression cases also use the baseline `.build/fixtures` inputs, generated by `scripts/make-fixtures.sh`. Hardware tests require VideoToolbox/IOSurface access outside the restricted shell sandbox.

## Limitations and integration

- External text must be UTF-8 or BOM-marked UTF-16. Convert legacy encodings before importing. Bitmap subtitles are unsupported and reported separately.
- WebVTT cue positioning and CSS are not retained. ASS colors use literal RGB, omitting legacy YCbCr matrix compensation. Color-matched legacy signs can differ slightly.
- Font attachments are capped at 64 MB per source. CoreText supplies system fonts; Apple fonts are not redistributed. Missing fonts use libass fallback.
- Container scanning cannot be interrupted while inside FFmpeg. Extraction is cancellable but can read an entire long container. Slow scripts may skip live overlay updates; final rendering takes as long as needed. The private libass build disables assembly optimizations.
- A native 16 ms timer updates the overlay from playback time. It is not synchronized to a display-link refresh, so live cue transitions may differ by a refresh or more under load. Paused frames and exports use exact frame timestamps. Odd source dimensions may differ by one pixel in preserved placement.
- Bundles are ad-hoc signed for Apple Silicon/macOS 14+, without notarization.

All new media libraries were built privately in this worktree. Unchanged dav1d/zimg inputs were copied from the baseline cache and their install paths made private. Packaging rejects non-system dylibs outside the private media prefix. Shared libraries, licenses, pinned dependency archives and recipes accompany the app. To rebuild the source ZIP, extract `Clipper-source.tar` into a new folder and copy `Dependencies/*` into its `.build/vendor/`, then run the scripts above.

Integration overlaps are `Editor`, `EditorView`, `Viewer`, `Export`, the build recipes and dependency packaging. Main and sibling branches were not changed or pushed. The original implementation was independent; the PR integration below subsequently merges current main into this feature branch.

Review artifacts, relative to this worktree:

- `dist/Clipper Subtitles.app`
- `dist/Clipper-Subtitles-macOS-arm64.zip`
- `dist/Clipper-Subtitles-Sources.zip`

The matching commit is recorded in `Clipper-Sources/COMMIT.txt` inside the source ZIP. Branch: `feature/hardsubs`.


## PR conflict resolution

PR #5 incorporates `origin/main` at `1573096`. The merge keeps waveform generation and cleanup, remembered export preferences, exported-clip handoff and source protection, URL range time mapping, importer recovery and workspace leases alongside the subtitle implementation and snapshot fixes.

The editor passes its verified original-time offset to the subtitle controller. External subtitle zero is `details.origin - importTimeline.offset`, so live frames and hardware exports use the same original-video cue clock. Container subtitles retain absolute timestamps with zero 0. The subtitle Convert to SDR action uses the existing preference-aware editor action. Claude checked the integration plan and combined editor hooks without finding a blocking issue.

The private media engine was rebuilt with both libass and main's HTTPS/SecureTransport configuration, including the certificate-verification patch. The cache check now requires both sets of capabilities. Matching sources include that patch and its hash receipt.

The merge suite ran 112 tests with zero failures and four optional network tests skipped. A separate opt-in loopback TLS test passed and confirmed untrusted certificate rejection. The suite covers the existing subtitle and source-protection tests plus waveform, preference/handoff, URL range/import, workspace and editor regressions. Three added integration cases cover actual trimmed hardware subtitle output from an original-time range, waveform/audio-track changes retaining subtitle selection, and preference-aware HDR-to-SDR controls. Logs are `.build/hardsubs-merge-tests.log` and `.build/hardsubs-merge-tls-tests.log`.

Reproduce the merge checks with:

```sh
bash scripts/make-waveform-fixtures.sh
bash scripts/test.sh --filter 'SubtitleTests|WaveformTests|ExportPreferencesTests|ExportHandoffTests|URLRangeTests|URLImportTests|ImportWorkspaceTests|ManagedImportToolsTests|PasteImportTests|TimelineTests|EditorWindowTests|MediaTests.testExportProtectsSourceThroughSymlinksAndHardLinks|MediaTests.testPublishingDoesNotReplaceWithoutConsentOrWhenNewFileIsMissing|MediaTests.testConfirmedExportReplacesOnlyAfterSuccessAndCancellationKeepsOutput|MediaTests.testHDRPreserveAndSDRConversion'
CLIPPER_RANGE_NETWORK_TEST=1 bash scripts/test.sh --filter URLRangeTests.testNetworkBuildRejectsBadCertificatesByDefault
bash scripts/check-media.sh
```

The review ZIPs above are rebuilt for the merge commit. Their matching source receipt identifies the exact revision. Native interactive popover and playback review remains manual.
