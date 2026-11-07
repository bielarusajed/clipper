# Optional audio waveform

Read [shared execution rules](README.md) before implementation. Work only on this feature in its assigned T3 worktree.

Add an optional audio waveform alongside/below the filmstrip, useful at close zoom for locating word starts and silence. Preserve the existing accurate trim and zoom interactions and the window-fit layout. Keep the normal editor uncluttered with a small native toggle/menu action.

Build actual peaks from the selected audio track, aligned by source presentation time, including offset/VFR containers. No waveform for a source without audio. Refresh or invalidate on audio-track/source changes. Generate and cache in the background with cancellation, bounded memory and no full-file PCM retention or blocking preparation before editing. Playback/seek responsiveness has priority over waveform generation.

Acceptance: verify known synthetic audio peaks at correct times, changing tracks and zoom, cancellation/close, and a long-source bounded-memory path. Explain initial-generation behavior and provide a runnable review build.

