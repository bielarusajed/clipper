import AppKit
import SwiftUI

enum EditorWindowLayout {
    static let starterSize=CGSize(width:520,height:440)
    static let starterMinimum=CGSize(width:420,height:400)
    static let editorWidth:CGFloat=1180
    static let editorMinimumWidth:CGFloat=1010
    static let inset:CGFloat=12
    static let spacing:CGFloat=12
    static let sidebarWidth:CGFloat=288
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

/// Resizes the native window without replacing SwiftUI's window delegate.
struct EditorWindow:NSViewRepresentable {
    let source:URL?
    let videoSize:CGSize?
    var onAvailableSize:(CGSize)->Void

    func makeNSView(context:Context)->WindowHook { WindowHook() }
    func updateNSView(_ view:WindowHook,context:Context) {
        view.onAvailableSize=onAvailableSize
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
        private var observers:[NSObjectProtocol]=[]
        var onAvailableSize:((CGSize)->Void)?

        func update(source:URL?,videoSize:CGSize?) {
            let ratio=videoSize.flatMap { size in
                size.width.isFinite && size.height.isFinite && size.width>0 && size.height>0 ? size.width/size.height : nil
            }
            guard self.source != source || aspectRatio != ratio else { return }
            self.source=source; aspectRatio=ratio
            scheduleFit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            window.appearance=nil
            window.titlebarAppearsTransparent=true
            window.toolbar=nil
            window.isOpaque=false
            window.backgroundColor = .clear
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
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
                    let videoHeight=window.contentLayoutRect.height-EditorWindowLayout.surroundingSize.height
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
            if window.styleMask.contains(.fullScreen) {
                onAvailableSize?(CGSize(width:CGFloat.infinity,height:CGFloat.infinity))
                return
            }
            fitting=true
            defer { fitting=false }
            let visible=screen.visibleFrame
            // The SwiftUI editor lives below the title bar, including with full-size content.
            let titleHeight=window.frame.height-window.contentLayoutRect.height
            let available=CGSize(width:visible.width,height:max(1,visible.height-titleHeight))
            // Share the bounds with SwiftUI so its hosting view preserves the cap
            // when it refreshes the native window's constraints.
            onAvailableSize?(available)
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
            window.minSize=CGSize(width:minimum.width,height:minimum.height+titleHeight)
            window.maxSize=visible.size
            var frame=window.frame
            // Keep the top edge and horizontal center stable as videos change shape.
            frame.origin.x += (frame.width-size.width)/2
            frame.origin.y += frame.height-size.height-titleHeight
            frame.size=CGSize(width:size.width,height:size.height+titleHeight)
            if source == nil {
                frame.origin=CGPoint(x:visible.midX-frame.width/2,y:visible.midY-frame.height/2)
            }
            frame.origin.x=max(visible.minX,min(frame.origin.x,visible.maxX-frame.width))
            frame.origin.y=max(visible.minY,min(frame.origin.y,visible.maxY-frame.height))
            if window.frame != frame { window.setFrame(frame,display:true) }
            lastSize=window.frame.size
        }

        func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers=[]
        }
        deinit { stopObserving() }
    }
}
