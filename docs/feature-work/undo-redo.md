# Undo and redo

Read [shared execution rules](README.md) before implementation. Work only on this feature in its assigned T3 worktree.

Implement native undo/redo for trim boundaries, crop preset/ratio/position/size, and user-adjustable export/audio settings. Cmd-Z and Shift-Cmd-Z should work through the native undo manager while text fields retain normal text editing.

One completed timeline/crop drag or slider gesture is one undo entry; typed timestamps commit once. Undo/redo must restore a valid complete edit, update the preview and controls, and invalidate stale encoded previews. Initial loading, programmatic normalization and switching sources must not create misleading undo entries or apply history to a different source. Resolve export-in-progress and rapid gesture edge cases.

Acceptance: demonstrate undo/redo across several different edits, coalescing of a drag, redo invalidation after a new edit, and history reset on a new file. Include focused model/integration checks and a runnable review build.

