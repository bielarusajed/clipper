# Configurable burned-in subtitles

Read [shared execution rules](README.md) before implementation. Work only on this feature in its assigned T3 worktree.

Implement a first working burned-in subtitle feature, not soft subtitle muxing. Required text formats: ASS/SSA, SRT and WebVTT; support other formats only when they can be rendered correctly and report unsupported formats clearly.

Styling:
- Preserve ASS/SSA authored styles by default, with an explicit override option.
- For unstyled subtitles such as SRT, suggest and use a plausible readable default: a system/sans-serif font, white text with dark outline/shadow, bottom-center placement and safe margins, scaled sensibly for output resolution.
- Unstyled rendering and the optional override for styled subtitles use ONE shared configurable style model and UI.
- Let the user customize that style in a nonblocking anchored popover, opened by a small common icon button. Keep controls useful and modest (font/size, colors, outline/shadow or background, placement/margins as appropriate). Resolve ASS inline tags, positioning, fonts/attachments and force-style semantics with Claude; document what override changes.

Subtitle source UI:
- An enable switch defaults off; the section remains available even without container subtitles because external files can be selected.
- Offer Container / External tabs or equivalent ONLY when container subtitles exist. When none exist, show external file input directly.
- For Container, show a track picker only when multiple eligible subtitle tracks exist; one track needs no redundant selector.
- For External, show a file picker/input. Use the common style-popover button for either source.
- Keep an imported subtitle selection through relevant edits, but correctly reset stale state on source replacement and handle missing/unsupported files.

Rendering:
- Keep live/paused source preview, encoded quality preview and final output consistent in timing and appearance. Subtitle timing must remain correct across source origin offsets, trimmed clips, VFR, rotation, crop/downscale and URL imports. Decide explicitly whether placement is in final output coordinates.
- Keep video hardware-only encoding and the source-protection/confirmed-replacement export policy.
- The current FFmpeg build may need libass or an equivalent rendering path. Use properly redistributable dependencies, bundled dylibs/fonts where required, reproducible recipes and updated licenses/source packaging. Do not ship a Homebrew/GPL build. Keep all new dependency builds PRIVATE to this worktree rather than mutating shared prebuilt caches.
- Preserve an explicit, tested HDR/SDR policy instead of silently breaking colors or dropping subtitles. Consult Claude on architecture and any uncertain rendering/dependency decisions.

Acceptance: real external SRT/VTT and styled ASS/SSA, embedded one/multiple tracks, styled default vs common override, popover edits, correct in/out timing, crop/downscale placement, missing-file/unsupported-track handling and source cleanup. Include focused fixtures/tests and a usable self-contained review app. Describe limitations plainly; reach a plausible working end-to-end version, not just UI stubs.

