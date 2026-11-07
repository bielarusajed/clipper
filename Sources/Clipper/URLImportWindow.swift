import AppKit
import SwiftUI

/// Owns the import window for as long as the editor's window exists.
struct URLImportPresenter:NSViewRepresentable {
    @ObservedObject var editor:Editor
    func makeCoordinator()->Coordinator { Coordinator(editor:editor) }
    func makeNSView(context:Context)->Anchor {
        let view=Anchor()
        view.windowChanged={ [weak coordinator=context.coordinator] window in coordinator?.update(parent:window) }
        return view
    }
    func updateNSView(_ view:Anchor,context:Context) { context.coordinator.update(parent:view.window) }
    static func dismantleNSView(_ view:Anchor,coordinator:Coordinator) { coordinator.dismiss() }

    final class Anchor:NSView {
        var windowChanged:((NSWindow?)->Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowChanged?(window) }
    }

    @MainActor final class Coordinator {
        let editor:Editor
        private var controller:URLImportWindowController?
        init(editor:Editor) { self.editor=editor }
        func update(parent:NSWindow?) {
            guard let parent, editor.importPresented else { dismiss(); return }
            guard controller == nil else { return }
            let window=URLImportWindowController(importer:editor.urlImporter,parent:parent,
                open:{ [weak editor] download in
                    guard let editor else { return }
                    editor.importPresented=false
                    editor.open(download.file,temporary:download)
                },onClose:{ [weak self] in
                    self?.controller=nil
                    if self?.editor.importPresented == true { self?.editor.importPresented=false }
                })
            controller=window
            window.showWindow(nil)
            window.window?.makeKeyAndOrderFront(nil)
        }
        func dismiss() {
            let old=controller; controller=nil
            old?.close()
        }
    }
}

@MainActor final class URLImportWindowController:NSWindowController,NSWindowDelegate {
    private let importer:URLImport
    private let onClose:()->Void
    private var parentClose:NSObjectProtocol?
    private var keyMonitor:Any?

    init(importer:URLImport,parent:NSWindow,open:@escaping(TemporaryImport)->Void,onClose:@escaping()->Void) {
        self.importer=importer; self.onClose=onClose
        let panel=ImportPanel(contentRect:NSRect(x:0,y:0,width:URLImportLayout.width,height:URLImportLayout.compactHeight),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        super.init(window:panel)
        panel.title="Import URL"
        panel.isReleasedWhenClosed=false
        panel.hidesOnDeactivate=false
        panel.delegate=self
        panel.chooseFormats={ [weak importer] in importer?.showFormats() }
        panel.download={ [weak importer] in importer?.download(open:open) }
        keyMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak panel] event in
            guard let panel, NSApp.keyWindow === panel else { return event }
            return panel.handleReturn(event) ? nil : event
        }
        let content=URLImportView(importer:importer,open:open,close:{ [weak panel] in panel?.performClose(nil) })
            .background { [weak panel] in
                GeometryReader { [weak panel] geometry in
                    Color.clear.onChange(of:geometry.size,initial:true) { [weak panel] _,size in
                        if let panel { Self.resize(panel,to:size) }
                    }
                }
            }
        panel.contentView=NSHostingView(rootView:content)
        Self.resize(panel,to:NSSize(width:URLImportLayout.width,height:URLImportLayout.compactHeight))
        let frame=panel.frame
        let visible=parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        let expanded=panel.frameRect(forContentRect:NSRect(x:0,y:0,width:URLImportLayout.width,height:URLImportLayout.expandedHeight)).height
        // Reserve room below the URL row so revealing or filling the table keeps that row still.
        let top=min(visible.maxY-24,max(parent.frame.maxY-32,visible.minY+min(expanded,visible.height-24)))
        panel.setFrameOrigin(NSPoint(x:max(visible.minX,min(parent.frame.midX-frame.width/2,visible.maxX-frame.width)),y:top-frame.height))
        parentClose=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:parent,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }
    required init?(coder:NSCoder) { nil }
    deinit {
        if let parentClose { NotificationCenter.default.removeObserver(parentClose) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func windowWillClose(_ notification:Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor=nil }
        importer.endPresentation()
        onClose()
    }

    private static func resize(_ window:NSWindow,to size:CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let old=window.frame
        var frame=window.frameRect(forContentRect:NSRect(origin:.zero,size:size))
        frame.origin=NSPoint(x:old.midX-frame.width/2,y:old.maxY-frame.height)
        if let screen=window.screen {
            frame.origin.x=max(screen.visibleFrame.minX,min(frame.minX,screen.visibleFrame.maxX-frame.width))
            frame.origin.y=max(screen.visibleFrame.minY,min(frame.minY,screen.visibleFrame.maxY-frame.height))
        }
        if window.frame != frame { window.setFrame(frame,display:true) }
    }

    private final class ImportPanel:NSPanel {
        var chooseFormats:(()->Void)?
        var download:(()->Void)?
        func handleReturn(_ event:NSEvent)->Bool {
            guard [36,76].contains(event.keyCode) else { return false }
            let modifiers=event.modifierFlags.intersection([.command,.control,.option,.shift])
            if modifiers == .command {
                chooseFormats?(); return true
            }
            if modifiers.isEmpty { download?(); return true }
            return false
        }
        override func performKeyEquivalent(with event:NSEvent)->Bool {
            if handleReturn(event) { return true }
            return super.performKeyEquivalent(with:event)
        }
        override func cancelOperation(_ sender:Any?) { performClose(sender) }
    }
}
