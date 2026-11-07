import AppKit
import SwiftUI

enum EditorWindowLayout {
    static let starterSize=CGSize(width:520,height:440)
    static let starterMinimum=CGSize(width:420,height:400)
    static let editorWidth:CGFloat=1180
    static let editorMinimumWidth:CGFloat=1010
    static let inset:CGFloat=8
    static let spacing:CGFloat=8
    static let sidebarWidth:CGFloat=300
    static let headerPadding:CGFloat=14
    static let headerSpacing:CGFloat=8
    static let selectorHeight:CGFloat=30
    static let transportHeight:CGFloat=27
    static let timelineHeight:CGFloat=156
    static let timelineSpacing:CGFloat=9
    static let timelinePadding:CGFloat=12

    static var surroundingSize:CGSize {
        CGSize(width:inset*2+sidebarWidth+spacing,
               height:inset*2+selectorHeight+spacing*2+transportHeight+timelineSpacing+timelineHeight+timelinePadding*2)
    }

    static func videoSize(width:CGFloat,aspectRatio:CGFloat,available:CGSize)->CGSize {
        let ratio=aspectRatio.isFinite && aspectRatio>0 ? aspectRatio : 16/9
        let chrome=surroundingSize
        let videoWidth=max(1,min(width-chrome.width,available.width-chrome.width,(available.height-chrome.height)*ratio))
        return CGSize(width:videoWidth+chrome.width,height:ceil(videoWidth/ratio)+chrome.height)
    }
}

/// Read-only native geometry. AppKit owns placement and tracking; SwiftUI reserves
/// room around the actual controls, including when they leave for full screen.
struct WindowHeaderLayout:Equatable {
    var controls:CGRect?=CGRect(x:19,y:19,width:60,height:14)
    var height:CGFloat { max(36,((controls?.midY ?? 26)-EditorWindowLayout.inset)*2) }
    var reserve:CGFloat {
        guard let controls else { return 0 }
        return max(0,controls.maxX+12-EditorWindowLayout.inset-EditorWindowLayout.headerPadding-EditorWindowLayout.headerSpacing)
    }
    @MainActor init(window:NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { controls=nil; return }
        let buttons=[NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton].compactMap { window.standardWindowButton($0) }
        guard let first=buttons.first else { return }
        let rect=buttons.dropFirst().reduce(first.convert(first.bounds,to:nil)) { $0.union($1.convert($1.bounds,to:nil)) }
        controls=CGRect(x:rect.minX,y:window.frame.height-rect.maxY,width:rect.width,height:rect.height)
    }
    init() { }
}

/// Resizes the native window without replacing SwiftUI's window delegate.
struct EditorWindow:NSViewRepresentable {
    let source:URL?
    let videoSize:CGSize?
    var onAvailableSize:(CGSize)->Void
    var onHeaderLayout:((WindowHeaderLayout)->Void)?=nil

    func makeNSView(context:Context)->WindowHook { WindowHook() }
    func updateNSView(_ view:WindowHook,context:Context) {
        view.onAvailableSize=onAvailableSize
        view.onHeaderLayout=onHeaderLayout
        view.update(source:source,videoSize:videoSize)
    }
    static func dismantleNSView(_ view:WindowHook,coordinator:()) { view.stopObserving() }

    final class WindowHook:NSView {
        private var source:URL?
        private var aspectRatio:CGFloat?
        private var editorWidth=EditorWindowLayout.editorWidth
        private var lastSize=CGSize.zero
        private var fitting=false
        private var scheduled=false
        private var appearanceScheduled=false
        private let nativeToolbar=NSToolbar(identifier:"ClipperWindowHeader")
        private var centerAfterOpen=false
        private var observers:[NSObjectProtocol]=[]
        var onAvailableSize:((CGSize)->Void)?
        var onHeaderLayout:((WindowHeaderLayout)->Void)?

        func update(source:URL?,videoSize:CGSize?) {
            scheduleAppearance()
            let ratio=videoSize.flatMap { size in
                size.width.isFinite && size.height.isFinite && size.width>0 && size.height>0 ? size.width/size.height : nil
            }
            guard self.source != source || aspectRatio != ratio else { return }
            if self.source != source || (source != nil && ratio == nil) { centerAfterOpen=source != nil }
            self.source=source; aspectRatio=ratio
            scheduleFit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            applyAppearance(to:window)
            let center=NotificationCenter.default
            observers.append(center.addObserver(forName:NSWindow.didResizeNotification,object:window,queue:.main) { [weak self, weak window] _ in
                guard let self, let window, !self.fitting, !self.scheduled, !window.styleMask.contains(.fullScreen) else { return }
                let size=window.frame.size
                let widthChanged=abs(size.width-self.lastSize.width)>0.5
                let heightChanged=abs(size.height-self.lastSize.height)>0.5
                self.lastSize=size
                guard self.source != nil, widthChanged || heightChanged else { return }
                if widthChanged { self.editorWidth=size.width }
                else {
                    let videoHeight=window.frame.height-EditorWindowLayout.surroundingSize.height
                    self.editorWidth=EditorWindowLayout.surroundingSize.width+max(1,videoHeight)*(self.aspectRatio ?? 16/9)
                }
                self.scheduleFit()
            })
            for name in [NSWindow.didChangeScreenNotification,NSWindow.didEnterFullScreenNotification,NSWindow.didExitFullScreenNotification] {
                observers.append(center.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in self?.scheduleFit() })
            }
            observers.append(center.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in self?.scheduleFit() })
            scheduleFit()
        }

        private func applyAppearance(to window:NSWindow) {
            let title=source?.lastPathComponent ?? "Clipper"
            if window.title != title { window.title=title }
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            if window.tabbingMode != .disallowed { window.tabbingMode = .disallowed }
            if window.appearance != nil { window.appearance=nil }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent=true }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
            // Let AppKit own the widgets, their glass renderer and shared rollover.
            // The inspector header is laid out around this standard toolbar row.
            if window.toolbar !== nativeToolbar {
                nativeToolbar.allowsUserCustomization=false
                nativeToolbar.displayMode = .iconOnly
                window.toolbar=nativeToolbar
            }
            if window.isOpaque { window.isOpaque=false }
            if window.backgroundColor.alphaComponent != 0 { window.backgroundColor = .clear }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        }

        private func scheduleAppearance() {
            guard !appearanceScheduled else { return }
            appearanceScheduled=true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.appearanceScheduled=false
                if let window=self.window {
                    self.applyAppearance(to:window)
                    self.onHeaderLayout?(WindowHeaderLayout(window:window))
                }
            }
        }

        private func scheduleFit() {
            guard !scheduled else { return }
            scheduled=true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled=false; self.fit()
            }
        }

        func fit() {
            guard let window, let screen=window.screen ?? NSScreen.main else { return }
            fitting=true
            defer { fitting=false }
            if window.styleMask.contains(.fullScreen) {
                onHeaderLayout?(WindowHeaderLayout(window:window))
                onAvailableSize?(CGSize(width:CGFloat.infinity,height:CGFloat.infinity))
                return
            }
            applyAppearance(to:window)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            onHeaderLayout?(WindowHeaderLayout(window:window))
            let visible=screen.visibleFrame
            // The hidden-title-bar workspace occupies the entire native window.
            let available=visible.size
            // SwiftUI measures its maximum size below the toolbar, even when
            // ignoresSafeArea draws the workspace across the entire window.
            let toolbarHeight=max(0,window.frame.height-window.contentLayoutRect.height)
            onAvailableSize?(CGSize(width:visible.width,height:max(1,visible.height-toolbarHeight)))
            let size:CGSize
            let minimum:CGSize
            if source != nil {
                let ratio=aspectRatio ?? 16/9
                size=EditorWindowLayout.videoSize(width:editorWidth,aspectRatio:ratio,available:available)
                minimum=EditorWindowLayout.videoSize(width:min(editorWidth,EditorWindowLayout.editorMinimumWidth),aspectRatio:ratio,available:available)
            } else {
                size=EditorWindowLayout.starterSize
                minimum=EditorWindowLayout.starterMinimum
            }
            // Full-size content covers the whole frame. The content constraints
            // avoid AppKit adding a toolbar-dependent offset to setMaxSize.
            window.contentMinSize=minimum
            window.contentMaxSize=visible.size
            var frame=window.frame
            // Keep the top edge and horizontal center stable as videos change shape.
            frame.origin.x += (frame.width-size.width)/2
            frame.origin.y += frame.height-size.height
            frame.size=size
            if source == nil || centerAfterOpen {
                frame.origin=CGPoint(x:visible.midX-frame.width/2,y:visible.midY-frame.height/2)
            }
            frame.origin.x=max(visible.minX,min(frame.origin.x,visible.maxX-frame.width))
            frame.origin.y=max(visible.minY,min(frame.origin.y,visible.maxY-frame.height))
            if window.frame != frame { window.setFrame(frame,display:true) }
            lastSize=window.frame.size
            if aspectRatio != nil { centerAfterOpen=false }
        }

        func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers=[]
        }
        deinit { stopObserving() }
    }
}
