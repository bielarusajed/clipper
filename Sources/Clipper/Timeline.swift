import SwiftUI
import AppKit
import CoreImage
import CMedia

struct Timeline:View {
    @ObservedObject var editor:Editor
    @ObservedObject var playback:Playback
    @State private var visibleStart=0.0
    @State private var visibleEnd=0.0
    @State private var panTarget:Double?
    var body:some View {
        VStack(spacing:6) {
            overview
            TimelineSurface(editor:editor,position:editor.displayedPosition,zoom:pow(2,editor.timelineZoom),busy:playback.playing || playback.seeking || editor.previewPlaying || editor.comparisonPreparing,panTarget:panTarget) { start,end in
                visibleStart=start; visibleEnd=end
            }.frame(height:104) // Fits the 84-point canvas plus the legacy scrollbar.
            HStack(spacing:7) {
                keyHint("I","Set start")
                keyHint("O","Set end")
                HStack(spacing:4) {
                    Button { editor.stepFrame(-1) } label: { keycap("←") }.help("Previous frame (←)")
                    Button { editor.stepFrame(1) } label: { keycap("→") }.help("Next frame (→)")
                    Text("Step a frame").font(.system(size:9)).foregroundStyle(C1.muted)
                }.buttonStyle(.plain)
                Spacer()
                Image(systemName:"minus.magnifyingglass")
                Slider(value:$editor.timelineZoom,in:0...editor.maximumTimelineZoom).frame(width:115).controlSize(.mini).help("Zoom the timeline (⌘+/⌘− or pinch)")
                Image(systemName:"plus.magnifyingglass")
            }.font(.system(size:9)).foregroundStyle(C1.muted).frame(height:16)
        }.onChange(of:editor.source) { _,_ in visibleStart=0; visibleEnd=0; panTarget=nil }
    }
    private func keyHint(_ key:String,_ action:String)->some View {
        HStack(spacing:4) {
            keycap(key)
            Text(action).font(.system(size:9)).foregroundStyle(C1.muted)
        }.accessibilityElement(children:.combine)
    }
    private func keycap(_ key:String)->some View {
        Text(key).font(.system(size:9,weight:.medium,design:.monospaced)).foregroundStyle(C1.secondary)
            .padding(.horizontal,4).padding(.vertical,2)
            .background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:3))
            .overlay(RoundedRectangle(cornerRadius:3).stroke(C1.line,lineWidth:1))
    }
    private var overview:some View {
        VStack(spacing:3) {
            GeometryReader { geometry in
                let duration=max(0.001,editor.details?.duration ?? 1), width=geometry.size.width
                let range=max(0,visibleEnd-visibleStart), windowWidth=min(width,max(5,width*range/duration))
                ZStack(alignment:.leading) {
                    RoundedRectangle(cornerRadius:3).fill(C1.line.opacity(0.65))
                    RoundedRectangle(cornerRadius:2).fill(C1.blue.opacity(0.06)).overlay(RoundedRectangle(cornerRadius:2).stroke(C1.secondary.opacity(0.25),lineWidth:0.6))
                        .frame(width:windowWidth).offset(x:max(0,min(width-windowWidth,width*visibleStart/duration)))
                    RoundedRectangle(cornerRadius:1).fill(C1.amber).frame(width:max(2,width*editor.clipDuration/duration),height:5).offset(x:width*editor.inTime/duration)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { value in panTarget=max(0,min(duration,value.location.x/width*duration)) }.onEnded { _ in panTarget=nil })
                .accessibilityLabel("Episode overview")
                .accessibilityHint("Click or drag to move the detailed timeline")
            }.frame(height:9)
            HStack {
                Text("00:00")
                Spacer()
                Text("Whole video")
                Spacer()
                Text(TimeText.format(editor.details?.duration ?? 0).dropLast(4))
            }.font(.system(size:8)).foregroundStyle(C1.muted).monospacedDigit()
        }
    }
}
struct TimelineSurface:NSViewRepresentable {
    @ObservedObject var editor:Editor
    var position:Double
    var zoom:Double
    var busy:Bool
    var panTarget:Double?
    var onViewport:(Double,Double)->Void
    func makeCoordinator()->Coordinator { Coordinator(onViewport:onViewport) }
    func makeNSView(context:Context)->NSScrollView {
        let scroll=TimelineScrollView()
        scroll.onMagnify={ editor.zoomTimeline(by:log2(max(0.01,1+$0))) }
        scroll.hasHorizontalScroller=true; scroll.hasVerticalScroller=false
        scroll.autohidesScrollers=true; scroll.scrollerStyle = .legacy
        scroll.drawsBackground=false; scroll.verticalScrollElasticity = .none
        let view=TimelineCanvas(frame:CGRect(x:0,y:0,width:800,height:84))
        scroll.documentView=view
        view.seek={ editor.seek($0) }; view.setStart={ editor.markStart($0) }; view.setEnd={ editor.markEnd($0) }
        context.coordinator.observe(scroll)
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view=scroll.documentView as? TimelineCanvas else { return }
        context.coordinator.onViewport=onViewport
        let duration=editor.details?.duration ?? 1
        let width=min(8_000_000,max(100,scroll.contentSize.width)*zoom)
        let changed=abs(view.frame.width-width)>1
        let center=scroll.contentView.bounds.midX/max(1,view.frame.width)
        let moved=abs(view.position-position)>0.000001
        view.duration=duration; view.start=editor.inTime; view.end=editor.outTime; view.position=position
        view.enabled = !editor.exporting && !editor.loading
        view.setBusy(busy); view.setFrameSize(CGSize(width:width,height:84)); view.setSource(editor.source)
        var target:Double?
        if changed { target=zoom>view.zoom ? position : center*duration }
        if let panTarget, context.coordinator.lastPan != panTarget { target=panTarget }
        context.coordinator.lastPan=panTarget
        let playhead=position/max(0.001,duration)*width
        if moved, panTarget == nil, !busy, (playhead<scroll.contentView.bounds.minX || playhead>scroll.contentView.bounds.maxX) { target=position }
        if let target {
            let x=max(0,min(width-scroll.contentSize.width,target/max(0.001,duration)*width-scroll.contentSize.width/2))
            scroll.contentView.scroll(to:CGPoint(x:x,y:0)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        view.zoom=zoom; view.needsDisplay=true
        context.coordinator.report()
    }
    final class Coordinator {
        var onViewport:(Double,Double)->Void
        weak var scroll:NSScrollView?
        var observer:NSObjectProtocol?
        var lastPan:Double?
        private var reportedStart = -1.0
        private var reportedEnd = -1.0
        init(onViewport:@escaping(Double,Double)->Void) { self.onViewport=onViewport }
        func observe(_ scroll:NSScrollView) {
            self.scroll=scroll; scroll.contentView.postsBoundsChangedNotifications=true
            observer=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in self?.report() }
        }
        func report() {
            guard let scroll, let view=scroll.documentView as? TimelineCanvas, view.bounds.width>0 else { return }
            let start=max(0,scroll.contentView.bounds.minX/view.bounds.width*view.duration)
            let end=min(view.duration,scroll.contentView.bounds.maxX/view.bounds.width*view.duration)
            guard abs(start-reportedStart)>0.0001 || abs(end-reportedEnd)>0.0001 else { return }
            reportedStart=start; reportedEnd=end
            view.viewportMoved()
            DispatchQueue.main.async { [weak self] in self?.onViewport(start,end) }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
final class TimelineScrollView:NSScrollView {
    var onMagnify:((Double)->Void)?
    override func magnify(with event:NSEvent) { onMagnify?(event.magnification) }
}
final class TimelineCanvas:NSView {
    override var isFlipped:Bool { true }
    var duration=1.0, start=0.0, end=1.0, position=0.0, zoom=1.0
    var enabled=true
    var seek:((Double)->Void)?
    var setStart:((Double)->Void)?
    var setEnd:((Double)->Void)?
    private var dragMode=0
    private var lastDrag=Date.distantPast
    private var url:URL?
    private var images:[Int:NSImage]=[:]
    private var pending=Set<Int>()
    private var generation=0
    private let decode=DispatchQueue(label:"clipper.thumbnails",qos:.utility)
    private var media:OpaquePointer?
    private let ci=CIContext(options:[.cacheIntermediates:false])
    private let cancellation=clip_request_create()!
    private var busy=false
    private var viewportOrigin=Double.nan
    func viewportMoved() {
        if !viewportOrigin.isFinite || abs(visibleRect.minX-viewportOrigin)>visibleRect.width/2 {
            viewportOrigin=visibleRect.minX; generation += 1; pending=[]; clip_request_set(cancellation,Int32(generation))
        }
    }
    func setBusy(_ value:Bool) {
        if value && !busy { generation += 1; pending=[]; clip_request_set(cancellation,Int32(generation)) }
        busy=value
    }
    func setSource(_ source:URL?) {
        guard source != url else { return }
        url=source; generation += 1; images=[:]; pending=[]; clip_request_set(cancellation,Int32(generation))
        decode.async { [weak self] in
            guard let self else { return }
            if let media=self.media { clip_close(media) }; self.media=nil
            if let source { var error=[CChar](repeating:0,count:256); self.media=clip_open(source.path,-1,&error,256) }
        }
    }
    deinit { if let media { clip_close(media) }; clip_request_free(cancellation) }
    private func x(_ t:Double)->Double { t/max(duration,0.001)*bounds.width }
    private func time(_ x:Double)->Double { max(0,min(duration-0.000001,x/bounds.width*duration)) }
    override func draw(_ dirtyRect:NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        guard duration > 0 else { return }
        let visible=visibleRect.insetBy(dx:-100,dy:0).intersection(bounds)
        let span=duration/bounds.width*100
        let steps:[Double]=[0.001,0.002,0.005,0.01,0.02,0.05,0.1,0.2,0.5,1,2,5,10,15,30,60,120,300,600,1800,3600]
        let step=steps.first(where:{$0 >= span}) ?? 3600
        let first=floor(time(visible.minX)/step)*step
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular),.foregroundColor:NSColor.secondaryLabelColor]
        var t=first
        while t <= time(visible.maxX)+step {
            let xx=x(t)
            NSColor.separatorColor.setStroke(); let p=NSBezierPath(); p.move(to:CGPoint(x:xx,y:18)); p.line(to:CGPoint(x:xx,y:23)); p.stroke()
            let label=TimeText.format(t)
            (label as NSString).draw(at:CGPoint(x:xx+3,y:2),withAttributes:attrs)
            t += step
        }
        // Thumbnails are sparse and cached. Drawing only the visible rect supports deep zoom.
        let thumbWidth=96.0
        let from=Int(visible.minX/thumbWidth), to=Int(visible.maxX/thumbWidth)
        if from <= to {
            for n in from...to {
                let thumbTime=time(Double(n)*thumbWidth)
                let key=Int((thumbTime*1000).rounded())
                let rect=CGRect(x:Double(n)*thumbWidth,y:24,width:thumbWidth-1,height:45)
                if let image=images[key] { image.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil) }
                else { NSColor.quaternaryLabelColor.setFill(); rect.fill(); fetch(thumbTime,key:key) }
            }
        }
        let left=x(start), right=x(end)
        NSColor.windowBackgroundColor.withAlphaComponent(0.65).setFill()
        CGRect(x:0,y:24,width:left,height:45).intersection(dirtyRect).fill()
        CGRect(x:right,y:24,width:max(0,bounds.width-right),height:45).intersection(dirtyRect).fill()
        C1.selection.setStroke()
        let selection=NSBezierPath(rect:CGRect(x:left,y:23,width:max(2,right-left),height:47)); selection.lineWidth=2; selection.stroke()
        for xx in [left,right] where xx >= visible.minX-5 && xx <= visible.maxX+5 {
            C1.selection.setFill(); NSBezierPath(roundedRect:CGRect(x:xx-4,y:22,width:8,height:49),xRadius:2,yRadius:2).fill()
            NSColor.white.withAlphaComponent(0.8).setFill(); CGRect(x:xx-0.5,y:37,width:1,height:18).fill()
        }
        let playhead=x(position)
        C1.playhead.setStroke(); let line=NSBezierPath(); line.move(to:CGPoint(x:playhead,y:19)); line.line(to:CGPoint(x:playhead,y:74)); line.lineWidth=1.5; line.stroke()
        C1.playhead.setFill(); let tip=NSBezierPath(); tip.move(to:CGPoint(x:playhead-4,y:18)); tip.line(to:CGPoint(x:playhead+4,y:18)); tip.line(to:CGPoint(x:playhead,y:23)); tip.close(); tip.fill()
    }
    private func fetch(_ time:Double,key:Int) {
        guard !busy, !pending.contains(key), pending.count < 16 else { return }
        pending.insert(key); let token=generation
        decode.async { [weak self] in
            guard let self, let media=self.media else { return }
            let frame=clip_thumbnail(media,time,self.cancellation,Int32(token))
            var image:NSImage?
            if let unmanaged=frame.sample {
                let sample=unmanaged.takeRetainedValue()
                if let pixel=CMSampleBufferGetImageBuffer(sample) {
                    var ci=CIImage(cvPixelBuffer:pixel)
                    let rotation=clip_info(media).rotation
                    if abs(rotation)>45 {
                        ci=ci.oriented(forExifOrientation:rotation>135 || rotation < -135 ? 3 : rotation>0 ? 6 : 8)
                    }
                    let scale=160/ci.extent.width
                    ci=ci.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                    if let cg=self.ci.createCGImage(ci,from:ci.extent) { image=NSImage(cgImage:cg,size:.zero) }
                }
            }
            DispatchQueue.main.async {
                guard token==self.generation else { return }
                self.pending.remove(key)
                if self.images.count > 240 { self.images=[: ] }
                if let image { self.images[key]=image }
                self.needsDisplay=true
            }
        }
    }
    override func mouseDown(with event:NSEvent) {
        guard enabled else { return }
        let point=convert(event.locationInWindow,from:nil)
        dragMode=abs(point.x-x(start)) < 9 ? 1 : abs(point.x-x(end)) < 9 ? 2 : 0
        perform(point.x)
    }
    override func mouseDragged(with event:NSEvent) {
        guard enabled else { return }
        autoscroll(with:event)
        if Date().timeIntervalSince(lastDrag)>0.09 { perform(convert(event.locationInWindow,from:nil).x); lastDrag=Date() }
    }
    override func mouseUp(with event:NSEvent) { if enabled { perform(convert(event.locationInWindow,from:nil).x) } }
    private func perform(_ point:Double) {
        let t=time(point)
        switch dragMode { case 1: setStart?(min(t,end-0.001)); case 2: setEnd?(max(t,start)); default: seek?(t) }
    }
}
