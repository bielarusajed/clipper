import AppKit
import SwiftUI

/// References the completed output, never the disposable source or preview.
/// A replacement at the same path is intentionally treated as the current file.
@MainActor final class ExportedClip:ObservableObject {
    @Published private(set) var url:URL?
    @Published private(set) var available=false

    func set(_ url:URL?) { self.url=url; refresh() }

    @discardableResult func currentURL() -> URL? {
        guard let url, url.isFileURL,
              // URL resource values cache across calls, including after a move.
              // Stat the path each time rather than trusting cached URL metadata.
              let attributes=try? FileManager.default.attributesOfItem(atPath:url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath:url.path) else {
            if available { available=false }
            return nil
        }
        if !available { available=true }
        return url
    }

    func refresh() { _=currentURL() }
    func pasteboardWriter() -> NSURL? { currentURL().map { $0 as NSURL } }

    @discardableResult func copy(to pasteboard:NSPasteboard) -> Bool {
        // Validate before clearing, so an absent export leaves the clipboard alone.
        guard let writer=pasteboardWriter() else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([writer])
    }

    func reveal() {
        guard let url=currentURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func dragOperationMask(for context:NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

struct ExportHandoffView:View {
    @ObservedObject var clip:ExportedClip
    @State private var copied=false

    var body:some View {
        if let url=clip.url {
            VStack(alignment:.leading,spacing:5) {
                HStack(spacing:8) {
                    ExportFileDragView(clip:clip)
                        .frame(maxWidth:.infinity).frame(height:28)
                        .opacity(clip.available ? 1 : 0.5)
                        .help(clip.available ? "Drag a copy of \(url.lastPathComponent) into another app" : "File moved or removed. Export again to share it.")
                    Button(copied ? "Copied" : "Copy") {
                        copied=clip.copy(to:.general)
                    }.controlSize(.small).disabled(!clip.available)
                        .accessibilityLabel("Copy exported clip")
                }
                HStack {
                    Text(clip.available ? "Saved · Drag file to share" : "File moved or removed")
                        .lineLimit(1)
                    Spacer(minLength:4)
                    Button("Show in Finder") { clip.reveal() }
                        .buttonStyle(.plain).foregroundStyle(C1.blue).disabled(!clip.available)
                }.font(.system(size:9)).foregroundStyle(C1.secondary)
            }
            .onHover { _ in clip.refresh() }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in clip.refresh() }
            .onChange(of:url) { _,_ in copied=false }
            .onChange(of:clip.available) { _,available in if !available { copied=false } }
            .task(id:copied) {
                if copied {
                    do { try await Task.sleep(for:.seconds(2)); copied=false }
                    catch { }
                }
            }
            .task(id:url) {
                // Keep disabled states accurate even when Finder changes the file
                // while Clipper remains active. Every action also checks afresh.
                while !Task.isCancelled {
                    clip.refresh()
                    do { try await Task.sleep(for:.seconds(2)) }
                    catch { return }
                }
            }
        }
    }
}

/// AppKit controls the allowed operation so Finder cannot move the saved output.
struct ExportFileDragView:NSViewRepresentable {
    let clip:ExportedClip
    func makeNSView(context:Context) -> FileView { FileView() }
    func updateNSView(_ view:FileView,context:Context) { view.update(clip) }

    final class FileView:NSView,NSDraggingSource {
        private var clip:ExportedClip?
        private let icon=NSImageView()
        private let name=NSTextField(labelWithString:"")
        private var mouseDownPoint:NSPoint?

        override init(frame:NSRect) {
            super.init(frame:frame)
            icon.translatesAutoresizingMaskIntoConstraints=false
            name.translatesAutoresizingMaskIntoConstraints=false
            name.font = .systemFont(ofSize:10,weight:.medium)
            name.lineBreakMode = .byTruncatingMiddle
            name.maximumNumberOfLines=1
            name.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
            addSubview(icon); addSubview(name)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo:leadingAnchor),
                icon.centerYAnchor.constraint(equalTo:centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant:24),
                icon.heightAnchor.constraint(equalToConstant:24),
                name.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:6),
                name.trailingAnchor.constraint(equalTo:trailingAnchor),
                name.centerYAnchor.constraint(equalTo:centerYAnchor)
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityHelp("Drag this file into another app, or use the Copy button.")
        }
        required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(_ clip:ExportedClip) {
            self.clip=clip
            name.stringValue=clip.url?.lastPathComponent ?? ""
            icon.image=clip.url.map { NSWorkspace.shared.icon(forFile:$0.path) }
            setAccessibilityLabel("Exported clip: \(name.stringValue)")
        }
        override func hitTest(_ point:NSPoint) -> NSView? {
            // The whole icon/name is one drag target, including its text label.
            super.hitTest(point) == nil ? nil : self
        }
        override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
        override func shouldDelayWindowOrdering(for event:NSEvent) -> Bool { true }
        override func mouseDown(with event:NSEvent) { mouseDownPoint=event.locationInWindow }
        override func mouseUp(with event:NSEvent) { mouseDownPoint=nil }
        override func mouseDragged(with event:NSEvent) {
            guard let point=mouseDownPoint,
                  hypot(event.locationInWindow.x-point.x,event.locationInWindow.y-point.y)>3 else { return }
            mouseDownPoint=nil
            guard let writer=clip?.pasteboardWriter() else { return }
            let item=NSDraggingItem(pasteboardWriter:writer)
            item.setDraggingFrame(convert(icon.frame,from:icon.superview),contents:icon.image)
            beginDraggingSession(with:[item],event:event,source:self)
        }
        func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext) -> NSDragOperation {
            ExportedClip.dragOperationMask(for:context)
        }
        func ignoreModifierKeys(for session:NSDraggingSession) -> Bool { true }
    }
}
