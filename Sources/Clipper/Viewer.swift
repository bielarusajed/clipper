import SwiftUI
import AVKit
import CMedia

struct Viewer:View {
    @ObservedObject var editor:Editor
    @ObservedObject var playback:Playback
    @ObservedObject var subtitles:SubtitleController
    init(editor:Editor,playback:Playback) { self.editor=editor; self.playback=playback; self.subtitles=editor.subtitles }
    @State private var wipe=0.5

    var body:some View {
        VStack(spacing:EditorWindowLayout.spacing) {
            HStack {
                Spacer()
                HStack(spacing:3) {
                    ForEach(PreviewMode.allCases) { mode in
                        Button { editor.switchPreviewMode(mode) } label: {
                            Text(mode.rawValue).font(.system(size:11,weight:editor.previewMode == mode ? .medium : .regular))
                                .frame(width:66,height:24)
                                .foregroundStyle(editor.previewMode == mode ? C1.ink : C1.secondary)
                                .background(editor.previewMode == mode ? Color.primary.opacity(0.14) : .clear,in:RoundedRectangle(cornerRadius:5))
                        }.buttonStyle(.plain)
                            .disabled(mode != .original && !editor.previewReady)
                            .accessibilityAddTraits(editor.previewMode == mode ? .isSelected : [])
                            .accessibilityHint(mode != .original && !editor.previewReady ? "Render a five-second preview to enable this view" : "")
                            .help(mode == .original ? "Edit the original video" : editor.previewReady ? "Inspect the \(mode.rawValue.lowercased()) view" : "Render a five-second preview to enable this view")
                    }
                }.padding(3).background(C1.ink.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
                Spacer()
            }.frame(height:EditorWindowLayout.selectorHeight).disabled(editor.loading || editor.exporting)

            GeometryReader { geometry in
                if let details=playback.details {
                    let g=editor.edit.geometry(for:details)
                    let size=editor.previewMode == .original ? details.displaySize : CGSize(width:g.outWidth,height:g.outHeight)
                    let scale=min(geometry.size.width/size.width,geometry.size.height/size.height)
                    let display=CGSize(width:max(1,size.width*scale),height:max(1,size.height*scale))
                    ZStack {
                        ComparisonSurface(playback:playback,subtitles:subtitles.enabled && (!details.hdr || editor.edit.convertToSDR) ? subtitles.render : nil,source:playback.video,player:editor.outputPlayer,details:details,edit:editor.edit,mode:editor.previewMode,wipe:wipe,onWipe:{ wipe=$0 })
                        if editor.previewMode == .original, editor.edit.cropPreset != .original {
                            CropOverlay(editor:editor).disabled(editor.exporting || editor.loading)
                        }
                        if editor.previewMode == .compare {
                            HStack {
                                imageTag("Original")
                                Spacer()
                                imageTag("Output · \(editor.edit.codec.rawValue)")
                            }.padding(9).frame(maxHeight:.infinity,alignment:.bottom).allowsHitTesting(false)
                        }
                    }
                    .frame(width:display.width,height:display.height)
                    .clipShape(RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(.white.opacity(0.65),lineWidth:0.5))
                    .background(RoundedRectangle(cornerRadius:8).fill(.black).shadow(color:.black.opacity(0.12),radius:8,y:2).allowsHitTesting(false))
                    .position(x:geometry.size.width/2,y:geometry.size.height-display.height/2)
                } else {
                    Text(editor.loading ? "Preparing the video…" : "Choose another video to continue.")
                        .font(.callout).foregroundStyle(C1.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }

        }
    }

    private func imageTag(_ text:String)->some View {
        Text(text).font(.system(size:9,weight:.medium)).foregroundStyle(.white)
            .padding(.horizontal,7).padding(.vertical,4).background(.black.opacity(0.48),in:RoundedRectangle(cornerRadius:4))
    }

}

/// Both video layers keep one owner across all display modes. Only their layout
/// and the encoded layer's mask change when the user moves the comparison wipe.
struct ComparisonSurface:NSViewRepresentable {
    let playback:Playback
    let subtitles:RenderSubtitles?
    let source:AVSampleBufferDisplayLayer
    let player:AVPlayer
    let details:MediaDetails
    let edit:EditSettings
    let mode:PreviewMode
    let wipe:Double
    var onWipe:((Double)->Void)?
    func makeNSView(context:Context)->Surface { Surface(source:source,player:player) }
    func updateNSView(_ view:Surface,context:Context) {
        view.playback=playback; view.subtitleAsset=subtitles
        view.details=details; view.edit=edit; view.mode=mode; view.onWipe=onWipe
        if !view.draggingWipe { view.wipe=wipe }
        view.needsLayout=true
        view.window?.invalidateCursorRects(for:view)
    }
    static func dismantleNSView(_ view:Surface,coordinator:()) {
        if view.source.superlayer === view.sourceViewport { view.source.removeFromSuperlayer() }
        view.output.player=nil
        view.subtitleTimer?.cancel(); view.subtitleTimer=nil
    }
    final class Surface:NSView {
        let source:AVSampleBufferDisplayLayer
        weak var playback:Playback?
        var subtitleAsset:RenderSubtitles? {
            didSet {
                if oldValue?.identity != subtitleAsset?.identity {
                    if subtitleAsset == nil {
                        subtitleLayer.contents=nil
                        let worker=subtitleWorker
                        subtitleQueue.async { worker.clear() }
                    }
                }
            }
        }
        let subtitleLayer=CALayer()
        private let subtitleWorker=SubtitleOverlayWorker()
        let subtitleQueue=DispatchQueue(label:"clipper.subtitles",qos:.userInteractive)
        var subtitleTimer:DispatchSourceTimer?
        var subtitleBusy=false
        private var lastSubtitleRequest:SubtitleOverlayRequest?
        private struct SubtitleOverlayRequest:Equatable {
            let identity:UUID
            let milliseconds:Int64
            let width:Int
            let height:Int
            let canvas:CGRect
        }
        let sourceViewport=CALayer()
        let output:AVPlayerLayer
        let wipeMask=CALayer()
        let divider=CALayer()
        let knob=CATextLayer()
        var onWipe:((Double)->Void)?
        private(set) var draggingWipe=false
        var details:MediaDetails?
        var edit=EditSettings()
        var mode=PreviewMode.original
        var wipe=0.5
        init(source:AVSampleBufferDisplayLayer,player:AVPlayer) {
            self.source=source; output=AVPlayerLayer(player:player)
            super.init(frame:.zero)
            wantsLayer=true; layer=CALayer(); layer?.backgroundColor=NSColor.black.cgColor
            sourceViewport.masksToBounds=true
            sourceViewport.addSublayer(source); sourceViewport.addSublayer(subtitleLayer); layer?.addSublayer(sourceViewport)
            subtitleLayer.contentsGravity = .resize
            let timer=DispatchSource.makeTimerSource(queue:.main)
            timer.schedule(deadline:.now(),repeating:.milliseconds(16))
            timer.setEventHandler { [weak self] in self?.renderSubtitles() }
            timer.resume(); subtitleTimer=timer
            output.videoGravity = .resize; layer?.addSublayer(output)
            wipeMask.backgroundColor=NSColor.white.cgColor
            divider.backgroundColor=NSColor.white.cgColor
            layer?.addSublayer(divider)
            knob.string="↔"; knob.fontSize=17; knob.alignmentMode = .center
            knob.foregroundColor=NSColor.darkGray.cgColor; knob.backgroundColor=NSColor.white.cgColor
            knob.cornerRadius=14; knob.contentsScale=NSScreen.main?.backingScaleFactor ?? 2
            layer?.addSublayer(knob)
            setAccessibilityElement(true)
            setAccessibilityLabel("Comparison divider")
            setAccessibilityRole(.slider)
        }
        required init?(coder:NSCoder) { nil }
        override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); knob.contentsScale=window?.backingScaleFactor ?? 2 }
        override func hitTest(_ point:NSPoint)->NSView? {
            guard bounds.contains(convert(point,from:superview)) else { return nil }
            return super.hitTest(point)
        }
        override func resetCursorRects() {
            if mode == .compare { addCursorRect(CGRect(x:bounds.width*wipe-16,y:0,width:32,height:bounds.height),cursor:.resizeLeftRight) }
        }
        override func mouseDown(with event:NSEvent) {
            let point=convert(event.locationInWindow,from:nil)
            draggingWipe=mode == .compare && abs(point.x-bounds.width*wipe)<18
            if draggingWipe { moveDivider(to:point.x/bounds.width) }
            else { super.mouseDown(with:event) }
        }
        override func mouseDragged(with event:NSEvent) {
            if draggingWipe { moveDivider(to:convert(event.locationInWindow,from:nil).x/bounds.width) }
        }
        override func mouseUp(with event:NSEvent) {
            if draggingWipe { moveDivider(to:convert(event.locationInWindow,from:nil).x/bounds.width) }
            draggingWipe=false; onWipe?(wipe); window?.invalidateCursorRects(for:self)
        }
        func moveDivider(to fraction:Double) {
            wipe=max(0.02,min(0.98,fraction))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layoutDivider()
            CATransaction.commit()
        }
        override func accessibilityValue()->Any? { "\(Int(wipe*100)) percent original" }
        override func accessibilityPerformIncrement()->Bool { guard mode == .compare else { return false }; moveDivider(to:wipe+0.05); onWipe?(wipe); return true }
        override func accessibilityPerformDecrement()->Bool { guard mode == .compare else { return false }; moveDivider(to:wipe-0.05); onWipe?(wipe); return true }
        override func layout() {
            super.layout()
            guard let details else { return }
            let g=edit.geometry(for:details)
            let size=details.displaySize
            let comparing=mode != .original
            let sx=comparing ? bounds.width/Double(g.width) : bounds.width/size.width
            let sy=comparing ? bounds.height/Double(g.height) : bounds.height/size.height
            let full=CGSize(width:size.width*sx,height:size.height*sy)
            let rotated=abs(sin(details.rotation * .pi/180))>0.5
            CATransaction.begin(); CATransaction.setDisableActions(true)
            sourceViewport.frame=bounds
            source.setAffineTransform(.identity)
            source.bounds=CGRect(origin:.zero,size:rotated ? CGSize(width:full.height,height:full.width) : full)
            source.position=CGPoint(x:full.width/2-(comparing ? Double(g.x)*sx : 0),y:bounds.height-full.height/2+(comparing ? Double(g.y)*sy : 0))
            source.setAffineTransform(CGAffineTransform(rotationAngle:-details.rotation * .pi/180))
            sourceViewport.isHidden=mode == .output
            output.frame=bounds; output.isHidden=mode == .original
            layoutDivider()
            CATransaction.commit()
        }
        private func renderSubtitles() {
            guard let asset=subtitleAsset,let details,let playback,mode != .output else { if subtitleLayer.contents != nil { subtitleLayer.contents=nil }; lastSubtitleRequest=nil; return }
            guard !subtitleBusy else { return }
            let g=edit.geometry(for:details)
            let width=asset.preserve ? Int(details.displaySize.width/2)*2 : g.outWidth
            let height=asset.preserve ? Int(details.displaySize.height/2)*2 : g.outHeight
            let playing=playback.playing
            let ms=asset.milliseconds(frame:playing ? nil : playback.frame,relativeTime:playing ? playback.clock.currentTime().seconds : playback.position,origin:details.origin)
            let canvas:CGRect
            if mode == .original {
                let sx=bounds.width/details.displaySize.width,sy=bounds.height/details.displaySize.height
                canvas=asset.preserve ? bounds : CGRect(x:Double(g.x)*sx,y:bounds.height-Double(g.y+g.height)*sy,width:Double(g.width)*sx,height:Double(g.height)*sy)
            } else {
                let sx=bounds.width/Double(g.width),sy=bounds.height/Double(g.height)
                canvas=asset.preserve ? CGRect(x:-Double(g.x)*sx,y:bounds.height-Double(height-g.y)*sy,width:Double(width)*sx,height:Double(height)*sy) : bounds
            }
            let request=SubtitleOverlayRequest(identity:asset.identity,milliseconds:ms,width:width,height:height,canvas:canvas)
            guard request != lastSubtitleRequest else { return }
            lastSubtitleRequest=request
            subtitleBusy=true
            let worker=subtitleWorker
            subtitleQueue.async { [weak self] in
                let result=worker.render(asset:asset,milliseconds:ms,width:width,height:height)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }; self.subtitleBusy=false
                    guard self.subtitleAsset?.identity==asset.identity,self.mode != .output else { return }
                    let box=result.box
                    let frame=CGRect(x:canvas.minX+box.minX/Double(width)*canvas.width,y:canvas.minY+(Double(height)-box.maxY)/Double(height)*canvas.height,width:box.width/Double(width)*canvas.width,height:box.height/Double(height)*canvas.height)
                    guard result.changed || self.subtitleLayer.frame != frame || (self.subtitleLayer.contents == nil && result.image != nil) else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.subtitleLayer.contents=result.image; self.subtitleLayer.frame=frame
                    CATransaction.commit()
                }
            }
        }
        private func layoutDivider() {
            setAccessibilityElement(mode == .compare)
            divider.isHidden=mode != .compare; knob.isHidden=mode != .compare
            if mode == .compare {
                divider.frame=CGRect(x:bounds.width*wipe-0.75,y:0,width:1.5,height:bounds.height)
                knob.frame=CGRect(x:bounds.width*wipe-14,y:bounds.midY-14,width:28,height:28)
                wipeMask.frame=CGRect(x:bounds.width*wipe,y:0,width:bounds.width*(1-wipe),height:bounds.height)
                output.mask=wipeMask
            } else { output.mask=nil }
        }
    }
}

struct CropOverlay:View {
    @ObservedObject var editor:Editor
    @State private var original:CGRect?
    @State private var transaction:UUID?
    @GestureState private var dragging=false
    private var crop:CGRect { editor.edit.crop }
    private func begin() {
        if original == nil { transaction=editor.beginEditGesture("Crop"); original=crop }
    }
    private func finish() {
        editor.endEditGesture(transaction); transaction=nil; original=nil
    }
    var body:some View {
        GeometryReader { geo in
            let r=CGRect(x:crop.minX*geo.size.width,y:crop.minY*geo.size.height,width:crop.width*geo.size.width,height:crop.height*geo.size.height)
            ZStack(alignment:.topLeading) {
                Path { path in path.addRect(CGRect(origin:.zero,size:geo.size)); path.addRect(r) }.fill(.black.opacity(0.5),style:FillStyle(eoFill:true)).allowsHitTesting(false)
                Rectangle().fill(.clear).contentShape(Rectangle()).overlay(Rectangle().stroke(.white,lineWidth:1))
                    .frame(width:r.width,height:r.height).position(x:r.midX,y:r.midY)
                    .gesture(DragGesture(coordinateSpace:.named("crop")).updating($dragging) { _,state,_ in state=true }.onChanged { value in
                        begin()
                        guard let o=original else { return }
                        guard let transaction else { return }
                        editor.updateSettings("Crop",gesture:transaction) {
                            $0.crop.origin=CGPoint(x:max(0,min(1-o.width,o.minX+value.translation.width/geo.size.width)),y:max(0,min(1-o.height,o.minY+value.translation.height/geo.size.height)))
                        }
                    }.onEnded { _ in finish() })
                Image(systemName:"arrow.up.left.and.arrow.down.right").font(.system(size:12,weight:.bold)).foregroundStyle(.black).padding(5).background(.white,in:RoundedRectangle(cornerRadius:3))
                    .position(x:r.maxX-8,y:r.maxY-8)
                    .gesture(DragGesture(coordinateSpace:.named("crop")).updating($dragging) { _,state,_ in state=true }.onChanged { value in
                        begin()
                        guard let o=original else { return }
                        let factor=max(0.05,min((1-o.minX)/o.width,(1-o.minY)/o.height,1+value.translation.width/(o.width*geo.size.width)))
                        guard let transaction else { return }
                        editor.updateSettings("Crop",gesture:transaction) { $0.crop.size=CGSize(width:o.width*factor,height:o.height*factor) }
                    }.onEnded { _ in finish() })
            }.coordinateSpace(name:"crop")
        }.onChange(of:dragging) { _,active in if !active { finish() } }
            .onDisappear { finish() }
    }
}

/// This object is used only on Surface.subtitleQueue. Slow scripts drop overlay updates.
private final class SubtitleOverlayWorker: @unchecked Sendable {
    var renderer:OpaquePointer?
    var asset:RenderSubtitles?
    var image:CGImage?
    var box=CGRect.zero
    deinit { if let renderer { clip_subtitles_free(renderer) } }
    func clear() {
        if let renderer { clip_subtitles_free(renderer) }
        renderer=nil; asset=nil; image=nil; box = .zero
    }
    func render(asset:RenderSubtitles,milliseconds:Int64,width:Int,height:Int)->(image:CGImage?,box:CGRect,changed:Bool) {
        if self.asset?.identity != asset.identity {
            if let renderer { clip_subtitles_free(renderer) }
            renderer=clip_subtitles_open(asset.file.path,asset.fonts.path); self.asset=asset; image=nil; box = .zero
        }
        guard let renderer else { return (nil,.zero,true) }
        var x:Int32=0,y:Int32=0,changed:Int32=0
        let rendered=clip_subtitles_render(renderer,milliseconds,Int32(width),Int32(height),&x,&y,&changed)?.takeRetainedValue()
        if changed != 0 {
            image=rendered
            box=CGRect(x:Int(x),y:Int(y),width:rendered?.width ?? 0,height:rendered?.height ?? 0)
        }
        return (image,box,changed != 0)
    }
}
