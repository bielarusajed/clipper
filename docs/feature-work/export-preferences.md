# Remember export preferences

Read [shared execution rules](README.md) before implementation. Work only on this feature in its assigned T3 worktree.

Remember the user's chosen codec, quality and Save As destination folder between sessions using native preferences. Reopening a video should avoid repeating those choices. Use last explicit Save As folder for future Save As/imported-source dialogs, with Downloads as a sensible fallback if none is saved or the folder is unavailable. Preserve local one-click Export Clip's existing unique-file-beside-source behavior; do not silently redirect it.

Keep preferences minimal and consistent with the current Mac UI. Apply HDR/codec requirements safely: automatic HEVC for HDR must not overwrite the user's preferred SDR codec. Persist intentional user choices rather than source-load normalization. Trim/crop and source-specific audio-track choices remain per-video; session recovery is outside this task.

Acceptance: isolated UserDefaults tests for persistence, default values, HDR-to-SDR source switches, invalid/stale folder fallback and normal export behavior. Do not change the user's real preferences in tests. Provide a runnable review build.

