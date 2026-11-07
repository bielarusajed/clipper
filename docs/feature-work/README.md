# Independent feature implementation rules

This batch was explicitly authorized by the user on 7 November 2026. Implement only the assigned feature from this folder in the T3 thread's already-bound private worktree. The shared baseline is Clipper 0.4.3 at ab3bc2f, plus this planning-only commit. The user will later enter each individual thread to review its result.

## Execute to a working first version

1. Read the assigned brief, current README, docs/design-direction.md and any applicable repository instructions. Inspect the actual current code before choosing the integration points.
2. Consult Claude on the implementation plan and every substantive unresolved design/technical question. Use T3 delegate_task targeting providerInstanceId claudeAgent; call orchestrator_capabilities once in this new thread before the first delegation. Do not silently substitute another provider. If you disagree, present objections and debate until agreement. Claude is expected to become available at the scheduled kickoff. If rate limits persist, report that honestly, use independent discovery/test groundwork, and arrange continuation when a known reset is available rather than spinning or claiming consultation succeeded.
3. Implement autonomously until the first plausible end-to-end working version is ready. Choose reasonable small UX details yourself. Use native SwiftUI/AppKit and preserve the approved floating-glass workflow, responsive precise trimming, hardware-only video encoding, managed URL-import behavior, source protection and confirmed output replacement.
4. Have Claude review the resulting code against the feature brief and current behavior. Resolve substantive findings and disagreements. For each new review/re-check use a new delegate_task with the brief, previous findings and objections. Fix small findings yourself without requesting an unnecessary extra review.
5. Run meaningful checks appropriate to the changes, resolve failures, build a self-contained review app and commit the work in THIS feature branch. Keep main and other feature branches unchanged, with no automatic merges, pushes or PR creation. The user has authorized implementation, local commits, test fixtures and review builds; routine reversible work does not need another confirmation.
6. Finish with a short plain-language handoff: what feature is implemented, how to use it, what was checked, remaining limitations, branch/commit and absolute links to the review app ZIP and matching sources. Save concise reproducible handoff notes in this feature folder as well. A plan or nonfunctional UI stub is not the requested result.

## Independent worktrees and builds

Each of the seven features starts from the same baseline, so do not depend on another feature's unmerged implementation. Point out likely integration overlap in your handoff rather than merging siblings. The user will review each thread independently.

All writes, scratch outputs, test fixtures, generated apps and commits belong in your own worktree. The existing reusable dependency inputs are in /Users/bielarusajed/.t3/projects/clipper/.build. You may reuse media/vendor inputs read-only to avoid rebuilding unchanged FFmpeg/dav1d/zimg seven times. Keep Swift scratch/module caches, mutable fixtures, export outputs and dist private. If changing media dependencies or configure options, build into a private copy/prefix, never through symlinks into the shared dependency cache. Consult the repo's current build recipes and preserve its redistributable licensing and matching-source packaging.

Produce a review build with a distinct feature-specific app display name and bundle identifier, set on the staged bundle, so the user can open it alongside stable Clipper and the other review builds. Keep production version/release decisions for later integration. Review builds should not register themselves as the default Finder video handler. Do not overwrite another worktree's dist or the root project's release artifacts.

Use focused tests to avoid needlessly running seven simultaneous full hardware suites. Keep automatic checks out of the user's running app, general clipboard and system preferences. Use isolated named pasteboards/preferences and scratch files. If a native GUI check is needed, use the separate review app, not the user's current Clipper instance.

## Scope

The approved batch has seven independent features: undo/redo, selection loop/cut audition, copy/drag exported clips, optional audio waveform, rough URL-range import, remembered export preferences, and configurable burned-in subtitles. Session recovery and multiple named clip selections were ideas but are NOT part of this batch.

