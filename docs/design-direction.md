# Preferred UI direction

The user selected concept C, **Recipe & Loupe**, from the first prototype round as the best direction. This is the baseline for further UI work.

Preserve its compact Mac title bar, translucent left settings sidebar, grouped clip/framing/video/audio controls, pinned export actions, large comparison viewer, and overview plus detailed filmstrip timeline. Opening a file belongs in the empty state; closing the current file returns there.

The user then selected **C1, Frosted studio**, from the refinement round for implementation. C1 is the approved native app design. Use its cooler glass materials, quiet title chrome, grouped left sidebar, pinned preview/export actions, amber selection edges and slate playhead. The native implementation keeps the media engine and hardware export controls.

Original studies are preserved on `prototype/ui-studies` at `eaa1ee3`. Refinements are preserved on `prototype/c-refinements` at `f012eb9`. Those branches remain visual source material; the chosen design is implemented separately in SwiftUI and AppKit on `main`.

Compare is available after an actual encoded preview is ready. One persistent source display layer and an encoded AVPlayer layer share the same output crop geometry, with a draggable wipe. The encoded preview drives the clock. The original follows through coalesced decoded-frame requests, and paused steps align both sides to source frame boundaries. Closing a file returns to the empty state and cancels comparison work.

The user requested a native glass prototype to reconsider the contrasting inspector/viewer backgrounds. The throwaway `prototype/native-glass` branch at `d13784b` contains three switchable studies in the separate Clipper Glass Lab app: A Seamless, B Floating, and C Shelf. Their source and evaluation question are recorded in that branch's `docs/native-glass-prototype.md`. No glass study has been selected or adopted on main. The separate arrow keycap buttons are implemented on main at `3d1665d` and included in the prototype build.
