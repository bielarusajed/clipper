# Scheduled feature work

The user approved points 1–6 of the feature ideas plus burned-in subtitles. Seven independent T3 worktree threads were created without starting their agents. A one-time coordinator in the original conversation will dispatch their implementation messages at **7 November 2026, 03:25:01 Europe/Warsaw** (02:25:01 UTC), 65 minutes after scheduling preparation began.

Each worktree starts at planning commit `3f1c966`, with application code from 0.4.3 at `ab3bc2f`. Feature scope and Claude/worktree/build/handoff instructions are in this folder's [shared rules](README.md) and feature briefs. The user will review the separate branches and builds; the scheduled agents do not merge main automatically.

- Undo and redo: <t3-thread://v2/416a334f-4bfa-4837-9595-1b52af7587d9/mcp:launch:28705822c964777468aaa1928dfe35bcacac8bfc5003e5c587ae4f2eb3a223c2>
  Branch `feature/undo-redo`; brief [undo-redo.md](undo-redo.md).
- Selection loop and cut audition: <t3-thread://v2/416a334f-4bfa-4837-9595-1b52af7587d9/mcp:launch:590bd48df320b136db5f7df2ad2b2fd954d33e3a641ab2e24262ba2080db98df>
  Branch `feature/loop-audition`; brief [loop-audition.md](loop-audition.md).
- Copy and drag exported clips: <t3-thread://v2/416a334f-4bfa-4837-9595-1b52af7587d9/mcp:launch:ee79bc307f3265fb774d3dd4880f3c48092ff12febf61ef0794d48a31a21b4c4>
  Branch `feature/export-handoff`; brief [export-handoff.md](export-handoff.md).
- Optional audio waveform: <t3-thread://v2/416a334f-4bfa-4837-9595-1b52af7587d9/mcp:launch:e73ac46eb55e47d4798ba15e3947343fd14c3f78bba26e05c3bb7d992e93b884>
  Branch `feature/audio-waveform`; brief [audio-waveform.md](audio-waveform.md).
- Rough time-range URL imports: <t3-thread://v2/416a334f-4bfa-4837-9595-1b52af7587d9/mcp:launch:567b6ca0d06f05b609379fd6de6dd1500704bd3a7082537775121db58c2dc54d>
  Branch `feature/url-range-import`; brief [url-range-import.md](url-range-import.md).
- Remember export preferences: <t3-thread://v2/416a334f-4bfa-4837-9595-1b52af7587d9/mcp:launch:0134320667c60bb8fe2d221a4064aad34261269601098e9bc9de3d16cf65cd05>
  Branch `feature/export-preferences`; brief [export-preferences.md](export-preferences.md).
- Configurable burned-in subtitles: <t3-thread://v2/416a334f-4bfa-4837-9595-1b52af7587d9/mcp:launch:ae3e43a8828704cc139858822c5f36ac5b2abaf30b694e8f6dd9621f19f63c96>
  Branch `feature/hardsubs`; brief [hardsubs.md](hardsubs.md).

Schedule identifier: `scheduled-task:command:mcp:990c096a-8939-4789-80e3-9762960abf0f:schedule-task:clipper-seven-features-20261107-022501`.

The scheduler embeds the dispatch manifest and start messages, so launching does not depend on the root checkout still being on this branch. The coordinator verifies each target before sending; a thread already started or taken over by the user is left alone. Provider queueing or availability can affect when individual agents actually start.

