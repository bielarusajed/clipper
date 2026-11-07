import AppKit
import SwiftUI

/// Extend native window dragging over static file details. Interactive controls,
/// video and timeline retain their own mouse handling.
struct WindowDragRegion:NSViewRepresentable {
    func makeNSView(context:Context)->DragView { DragView() }
    func updateNSView(_ view:DragView,context:Context) { }
    final class DragView:NSView {
        override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
        override func mouseDown(with event:NSEvent) { window?.performDrag(with:event) }
    }
}
