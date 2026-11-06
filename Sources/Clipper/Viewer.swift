import SwiftUI
import AVKit

struct Viewer:View {
    @ObservedObject var editor:Editor
    @ObservedObject var playback:Playback
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var wipe=0.5
    @State private var initialWipe:Double?

    var body:some View {
        VStack(spacing:10) {
            HStack {
                Spacer()
                HStack(spacing:3) {
                    ForEach(PreviewMode.allCases) { mode in
                        Button { editor.switchPreviewMode(mode) } label: {
                            Text(mode.rawValue).font(.system(size:11,weight:editor.previewMode == mode ? .medium : .regular))
                                .frame(width:66,height:24)
                                .foregroundStyle(editor.previewMode == mode ? C1.ink : C1.secondary)
                                .background(editor.previewMode == mode ? Color.white : .clear,in:RoundedRectangle(cornerRadius:5))
                        }.buttonStyle(.plain)
                            .disabled(mode != .original && !editor.previewReady)
                            .accessibilityAddTraits(editor.previewMode == mode ? .isSelected : [])
                            .accessibilityHint(mode != .original && !editor.previewReady ? "Render a five-second preview to enable this view" : "")
                            .help(mode == .original ? "Edit the original video" : "Render a preview, then inspect the \(mode.rawValue.lowercased()) view")
                    }
                }.padding(3).background(C1.ink.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
                Spacer()
            }.disabled(editor.loading || editor.exporting)

            GeometryReader { geometry in
                if let details=playback.details {
                    let g=editor.edit.geometry(for:details)
                    let size=editor.previewMode == .original ? details.displaySize : CGSize(width:g.outWidth,height:g.outHeight)
                    let scale=min(geometry.size.width/size.width,geometry.size.height/size.height)
                    let display=CGSize(width:max(1,size.width*scale),height:max(1,size.height*scale))
                    ZStack {
                        ComparisonSurface(source:playback.video,player:editor.outputPlayer,details:details,edit:editor.edit,mode:editor.previewMode,wipe:wipe)
                        if editor.previewMode == .original, editor.edit.cropPreset != .original {
                            CropOverlay(crop:$editor.edit.crop).disabled(editor.exporting || editor.loading)
                        }
                        if editor.previewMode == .compare {
                            HStack {
                                imageTag("Original")
                                Spacer()
                                imageTag("Output · \(editor.edit.codec.rawValue)")
                            }.padding(9).frame(maxHeight:.infinity,alignment:.bottom).allowsHitTesting(false)
                            wipeHandle(height:display.height,width:display.width)
                                .position(x:display.width*wipe,y:display.height/2)
                        }
                    }
                    .frame(width:display.width,height:display.height)
                    .clipShape(RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).stroke(.white.opacity(0.65),lineWidth:0.5))
                    .shadow(color:C1.ink.opacity(0.18),radius:15,y:9)
                    .position(x:geometry.size.width/2,y:geometry.size.height/2)
                } else {
                    Text(editor.loading ? "Preparing the video…" : "Choose another video to continue.")
                        .font(.callout).foregroundStyle(C1.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }
            HStack(spacing:5) {
                Spacer()
                if editor.comparisonPreparing { ProgressView().controlSize(.mini); Text("Matching source frame…") }
                else if editor.previewReady { Circle().fill(Color.green.opacity(0.6)).frame(width:4,height:4); Text("\(editor.previewDuration.formatted(.number.precision(.fractionLength(0...2)))) s encoded preview ready") }
                else { Text("Render a five-second preview to compare quality") }
            }.font(.system(size:9)).foregroundStyle(C1.secondary).frame(height:13)
        }
        .padding(.horizontal,24).padding(.top,12).padding(.bottom,13)
        .background {
            GeometryReader { geometry in
                ZStack {
                    C1.canvas
                    if !reduceTransparency, let image=playback.backdrop {
                        Image(nsImage:image).resizable().scaledToFill()
                            .frame(width:geometry.size.width,height:geometry.size.height)
                            .blur(radius:35).opacity(0.15)
                    }
                }.clipped()
            }
        }
    }
    private func imageTag(_ text:String)->some View {
        Text(text).font(.system(size:9,weight:.medium)).foregroundStyle(.white)
            .padding(.horizontal,7).padding(.vertical,4).background(.black.opacity(0.48),in:RoundedRectangle(cornerRadius:4))
    }
    private func wipeHandle(height:Double,width:Double)->some View {
        ZStack {
            Color.white.frame(width:1.5,height:height).shadow(color:.black.opacity(0.3),radius:1)
            Image(systemName:"arrow.left.and.right").font(.system(size:11,weight:.medium)).foregroundStyle(C1.secondary)
                .frame(width:28,height:28).background(.white.opacity(0.95),in:Circle()).shadow(color:.black.opacity(0.2),radius:4,y:2)
        }
        .frame(width:29,height:height).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance:0).onChanged { value in
            if initialWipe == nil { initialWipe=wipe }
            wipe=max(0.02,min(0.98,(initialWipe ?? wipe)+value.translation.width/width))
        }.onEnded { _ in initialWipe=nil })
        .focusable(false).accessibilityLabel("Comparison divider")
        .accessibilityValue("\(Int(wipe*100)) percent original")
        .accessibilityAdjustableAction { direction in
            switch direction { case .increment: wipe=min(0.98,wipe+0.05); case .decrement: wipe=max(0.02,wipe-0.05); @unknown default: break }
        }
    }
}

/// Both video layers keep one owner across all display modes. Only their layout
/// and the encoded layer's mask change when the user moves the comparison wipe.
struct ComparisonSurface:NSViewRepresentable {
    let source:AVSampleBufferDisplayLayer
    let player:AVPlayer
    let details:MediaDetails
    let edit:EditSettings
    let mode:PreviewMode
    let wipe:Double
    func makeNSView(context:Context)->Surface { Surface(source:source,player:player) }
    func updateNSView(_ view:Surface,context:Context) {
        view.details=details; view.edit=edit; view.mode=mode; view.wipe=wipe; view.needsLayout=true
    }
    static func dismantleNSView(_ view:Surface,coordinator:()) {
        if view.source.superlayer === view.sourceViewport { view.source.removeFromSuperlayer() }
        view.output.player=nil
    }
    final class Surface:NSView {
        let source:AVSampleBufferDisplayLayer
        let sourceViewport=CALayer()
        let output:AVPlayerLayer
        let wipeMask=CALayer()
        var details:MediaDetails?
        var edit=EditSettings()
        var mode=PreviewMode.original
        var wipe=0.5
        init(source:AVSampleBufferDisplayLayer,player:AVPlayer) {
            self.source=source; output=AVPlayerLayer(player:player)
            super.init(frame:.zero)
            wantsLayer=true; layer=CALayer(); layer?.backgroundColor=NSColor.black.cgColor
            sourceViewport.masksToBounds=true
            sourceViewport.addSublayer(source); layer?.addSublayer(sourceViewport)
            output.videoGravity = .resize; layer?.addSublayer(output)
            wipeMask.backgroundColor=NSColor.white.cgColor
        }
        required init?(coder:NSCoder) { nil }
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
            if mode == .compare {
                wipeMask.frame=CGRect(x:bounds.width*wipe,y:0,width:bounds.width*(1-wipe),height:bounds.height)
                output.mask=wipeMask
            } else { output.mask=nil }
            CATransaction.commit()
        }
    }
}

struct CropOverlay:View {
    @Binding var crop:CGRect
    @State private var original:CGRect?
    var body:some View {
        GeometryReader { geo in
            let r=CGRect(x:crop.minX*geo.size.width,y:crop.minY*geo.size.height,width:crop.width*geo.size.width,height:crop.height*geo.size.height)
            ZStack(alignment:.topLeading) {
                Path { path in path.addRect(CGRect(origin:.zero,size:geo.size)); path.addRect(r) }.fill(.black.opacity(0.5),style:FillStyle(eoFill:true)).allowsHitTesting(false)
                Rectangle().fill(.clear).contentShape(Rectangle()).overlay(Rectangle().stroke(.white,lineWidth:1))
                    .frame(width:r.width,height:r.height).position(x:r.midX,y:r.midY)
                    .gesture(DragGesture().onChanged { value in
                        if original == nil { original=crop }
                        guard let o=original else { return }
                        crop.origin=CGPoint(x:max(0,min(1-o.width,o.minX+value.translation.width/geo.size.width)),y:max(0,min(1-o.height,o.minY+value.translation.height/geo.size.height)))
                    }.onEnded { _ in original=nil })
                Image(systemName:"arrow.up.left.and.arrow.down.right").font(.system(size:12,weight:.bold)).foregroundStyle(.black).padding(5).background(.white,in:RoundedRectangle(cornerRadius:3))
                    .position(x:r.maxX-8,y:r.maxY-8)
                    .gesture(DragGesture().onChanged { value in
                        if original == nil { original=crop }
                        guard let o=original else { return }
                        let factor=max(0.05,min((1-o.minX)/o.width,(1-o.minY)/o.height,1+value.translation.width/(o.width*geo.size.width)))
                        crop.size=CGSize(width:o.width*factor,height:o.height*factor)
                    }.onEnded { _ in original=nil })
            }
        }
    }
}
