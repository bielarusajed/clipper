# Rough time-range URL imports

Read [shared execution rules](README.md) before implementation. Work only on this feature in its assigned T3 worktree.

Extend the existing managed yt-dlp importer with an optional rough start/end range so a user seeking a few seconds of a long video can request a small surrounding window, then trim precisely in Clipper. Example: import roughly 08:00–08:30 for a cut near 08:13.5. Full-video import remains the default.

Keep format lookup/prefetch, selected video/audio formats, cancellation and managed tool updates. Consult Claude on yt-dlp range/keyframe behavior. Fetch appropriate padding and prove final local frame-accurate trimming; partial download boundaries themselves need not be exact. Maintain an explicit mapping between original-video time and local imported-media time so UI labels/export trim logic do not accidentally shift the cut. Handle timestamp-bearing URLs where useful without silently enabling an unwanted trim. Handle missing duration and unsupported/inefficient ranged sources honestly rather than promising universal network savings.

Acceptance: validate ranges, downloader arguments, original/local timestamp mapping and temporary-source cleanup; test a representative real URL when available and synthetic offset fixtures. Provide a runnable review build and document any site/format limitations.

