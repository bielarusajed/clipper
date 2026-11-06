import SwiftUI
import AppKit
import CoreImage
import CMedia

struct Timeline:View {
    @ObservedObject var editor:Editor
    @ObservedObject var playback:Playback
    @State private var zoom=0.0
    var body:some View {
        VStack(spacing:6) {
            TimelineSurface(editor:editor,position:playback.position,zoom:pow(2,zoom))
            HStack {
                Button("Fit") { zoom=0 }.controlSize(.mini)
                Spacer()
                Image(systemName:"minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value:$zoom,in:0...16).frame(width:160).help("Zoom the timeline for precise edits")
                Image(systemName:"plus.magnifyingglass").foregroundStyle(.secondary)
            }
        }
    }
}
struct TimelineSurface:NSViewRepresentable {
    @ObservedObject var editor:Editor
    var position:Double
    var zoom:Double
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=NSScrollView()
        scroll.hasHorizontalScroller=true; scroll.hasVerticalScroller=false; scroll.autohidesScrollers=false
        scroll.drawsBackground=false
        let view=TimelineCanvas(frame:CGRect(x:0,y:0,width:800,height:76))
        scroll.documentView=view
        view.seek={ editor.seek($0) }; view.setStart={ editor.markStart($0) }; view.setEnd={ editor.markEnd($0) }
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view=scroll.documentView as? TimelineCanvas else { return }
        let duration=editor.details?.duration ?? 1
        let width=max(100,scroll.contentSize.width)*zoom
        let changed=abs(view.frame.width-width) > 1
        let priorWidth=max(1,view.frame.width)
        let center=scroll.contentView.bounds.midX/priorWidth
        view.duration=duration; view.start=editor.inTime; view.end=editor.outTime; view.position=position
        view.enabled = !editor.exporting
        view.setFrameSize(CGSize(width:width,height:76))
        view.setSource(editor.source)
        if changed {
            let fraction=zoom > view.zoom ? position/max(0.001,duration) : center
            scroll.contentView.scroll(to:CGPoint(x:max(0,min(width-scroll.contentSize.width,fraction*width-scroll.contentSize.width/2)),y:0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        view.zoom=zoom
        view.needsDisplay=true
    }
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
    func setSource(_ source:URL?) {
        guard source != url else { return }
        url=source; generation += 1; images=[:]; pending=[]
        decode.async { [weak self] in
            guard let self else { return }
            if let media=self.media { clip_close(media) }; self.media=nil
            if let source { var error=[CChar](repeating:0,count:256); self.media=clip_open(source.path,-1,&error,256) }
        }
    }
    deinit { if let media { clip_close(media) } }
    private func x(_ t:Double)->Double { t/max(duration,0.001)*bounds.width }
    private func time(_ x:Double)->Double { max(0,min(duration-0.000001,x/bounds.width*duration)) }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.controlBackgroundColor.setFill(); dirtyRect.fill()
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
        NSColor.black.withAlphaComponent(0.48).setFill()
        CGRect(x:0,y:24,width:left,height:45).intersection(dirtyRect).fill()
        CGRect(x:right,y:24,width:max(0,bounds.width-right),height:45).intersection(dirtyRect).fill()
        NSColor.controlAccentColor.setStroke()
        let selection=NSBezierPath(rect:CGRect(x:left,y:23,width:max(2,right-left),height:47)); selection.lineWidth=2; selection.stroke()
        for xx in [left,right] where xx >= visible.minX-5 && xx <= visible.maxX+5 {
            NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect:CGRect(x:xx-4,y:22,width:8,height:49),xRadius:2,yRadius:2).fill()
            NSColor.white.withAlphaComponent(0.8).setFill(); CGRect(x:xx-0.5,y:37,width:1,height:18).fill()
        }
        let playhead=x(position)
        NSColor.labelColor.setStroke(); let line=NSBezierPath(); line.move(to:CGPoint(x:playhead,y:19)); line.line(to:CGPoint(x:playhead,y:74)); line.lineWidth=1.5; line.stroke()
        NSColor.labelColor.setFill(); let tip=NSBezierPath(); tip.move(to:CGPoint(x:playhead-4,y:18)); tip.line(to:CGPoint(x:playhead+4,y:18)); tip.line(to:CGPoint(x:playhead,y:23)); tip.close(); tip.fill()
    }
    private func fetch(_ time:Double,key:Int) {
        guard !pending.contains(key), pending.count < 30 else { return }
        pending.insert(key); let token=generation
        decode.async { [weak self] in
            guard let self, let media=self.media else { return }
            let frame=clip_frame(media,time)
            var image:NSImage?
            if let unmanaged=frame.sample {
                let sample=unmanaged.takeRetainedValue()
                if let pixel=CMSampleBufferGetImageBuffer(sample) {
                    var ci=CIImage(cvPixelBuffer:pixel)
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
