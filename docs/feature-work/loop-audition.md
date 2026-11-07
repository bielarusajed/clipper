# Selection loop and cut audition

Read [shared execution rules](README.md) before implementation. Work only on this feature in its assigned T3 worktree.

Add an unobtrusive way to loop the selected clip and a keyboard/menu action to audition the last second before the selected out point. The user should be able to judge a natural cut without changing the selection or manually seeking repeatedly.

Use the existing exact frame boundaries and warm playback path. Choose sensible shortcuts that do not conflict with text editing, I/O, frame arrows or timeline zoom. Define clear behavior in Original, Compare and Output modes, including a bounded encoded preview. Handle edits, pause, rapid toggles, source replacement and close while looping; avoid black flashes, stale callbacks and unnecessary cold seeks.

Acceptance: the selection replays accurately, audition stops at the chosen end and leaves markers unchanged, and interruption/close is reliable. Check short and VFR clips and provide a runnable review build.

