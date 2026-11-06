# Preferred UI direction

The user selected concept C, **Recipe & Loupe**, from the first prototype round as the best direction. This is the baseline for further UI work.

Preserve its compact Mac title bar, translucent left settings sidebar, grouped clip/framing/video/audio controls, pinned export actions, large comparison viewer, and overview plus detailed filmstrip timeline. Opening a file belongs in the empty state; closing the current file returns there.

The user then selected **C1, Frosted studio**, from the refinement round for implementation. C1 is the approved native app design. Use its cooler glass materials, quiet title chrome, grouped left sidebar, pinned preview/export actions, amber selection edges and slate playhead. The native implementation keeps the media engine and hardware export controls.

Original studies are preserved on `prototype/ui-studies` at `eaa1ee3`. Refinements are preserved on `prototype/c-refinements` at `f012eb9`. Those branches remain visual source material; the chosen design is implemented separately in SwiftUI and AppKit on `main`.

Compare is available after an actual encoded preview is ready. One persistent source display layer and an encoded AVPlayer layer share the same output crop geometry, with a draggable wipe. The encoded preview drives the clock. The original follows through coalesced decoded-frame requests, and paused steps align both sides to source frame boundaries. Closing a file returns to the empty state and cancels comparison work.

The user selected **B, Floating**, from the native glass studies and explicitly asked to apply it to the main app. This is the current design. The refined primary source is preserved on `prototype/native-glass` at `083c486`; its evaluation notes are in that branch's `docs/native-glass-prototype.md`.

The main app uses one window-wide native material, with floating glass inspector and timeline panels. There is a 12-point outer inset and gap between panels. The preview selector sits flush with the inspector's top edge. The video has no extra side inset, preserves its aspect ratio, and ends 12 points above the timeline. The old horizontal rule above the timeline is removed. Native glass is limited to controls and panels, with a fallback on earlier macOS versions and solid backgrounds for Reduce Transparency. The app follows system appearance. Prototype controls and unselected variants stay out of main.

The separate arrow keycap buttons are implemented on main at `3d1665d`.
