import SwiftUI
import AVKit

struct EditorView: View {
    @ObservedObject var editor: Editor
    @ObservedObject var playback: Playback
    @State private var dropping=false
    @State private var startText=""
    @State private var endText=""
    var body: some View {
        VStack(spacing:0) {
            if let details=playback.details, editor.source != nil {
                HStack(spacing:0) {
                    VStack(spacing:0) {
                        Viewer(editor:editor,playback:playback)
                            .frame(maxWidth:.infinity,maxHeight:.infinity)
                        transport
                    }
                    Divider()
                    inspector(details).frame(width:258)
                }
                Divider()
                VStack(spacing:12) {
                    HStack(spacing:16) {
                        timeField("Start",text:$startText,value:editor.inTime,commit:editor.markStart)
                        Button { editor.markStart() } label: { Image(systemName:"i.square") }.help("Set start at this frame (I)")
                        timeField("End",text:$endText,value:editor.end?.time ?? 0,commit:editor.markEnd)
                        Button { editor.markEnd() } label: { Image(systemName:"o.square") }.help("Include this frame as the end (O)")
                        Spacer()
                        Text("\(TimeText.format(editor.clipDuration)) selected").monospacedDigit().foregroundStyle(.secondary)
                    }.controlSize(.small)
                    Timeline(editor:editor,playback:playback).frame(height:110)
                }.padding(16).disabled(editor.exporting)
            } else { empty }
            Divider()
            footer
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .overlay { if dropping { RoundedRectangle(cornerRadius:8).stroke(Color.accentColor,lineWidth:3).padding(4).allowsHitTesting(false) } }
        .onDrop(of:[.fileURL],isTargeted:$dropping) { providers in
            guard !editor.exporting, let provider=providers.first else { return false }
            _=provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in editor.open(url) } } }; return true
        }
        .toolbar {
            ToolbarItem(placement:.navigation) { Button { editor.openPanel() } label: { Label("Open",systemImage:"folder") }.disabled(editor.exporting) }
            ToolbarItem(placement:.principal) {
                VStack(spacing:2) {
                    Text(editor.source?.lastPathComponent ?? "Clipper").font(.headline).lineLimit(1)
                    if let d=playback.details { Text("\(Int(d.displaySize.width)) × \(Int(d.displaySize.height))  \(d.codec.uppercased())\(d.hdr ? "  HDR" : "")").font(.caption).foregroundStyle(.secondary) }
                }.frame(minWidth:240).fixedSize()
            }
        }
        .onChange(of:editor.edit) { old,_ in editor.settingsChanged(old) }
        .onChange(of:editor.start) { _,_ in startText=TimeText.format(editor.inTime) }
        .onChange(of:editor.end) { _,value in endText=TimeText.format(value?.time ?? 0) }
        .alert("Clipper",isPresented:Binding(get:{ editor.error != nil || playback.error != nil },set:{ if !$0 { editor.error=nil; playback.error=nil } })) {
            Button("OK") { editor.error=nil; playback.error=nil }
        } message: { Text(editor.error ?? playback.error ?? "") }
    }
    private var empty: some View {
        VStack(spacing:18) {
            Image(systemName:"film.stack").font(.system(size:48,weight:.light)).foregroundStyle(.secondary)
            Text("Drop a video to make a clip").font(.title2.weight(.medium))
            Text("MP4, MOV, WebM, MKV and AVI").foregroundStyle(.secondary)
            Button("Open Video…") { editor.openPanel() }.buttonStyle(.borderedProminent).controlSize(.large)
            if playback.seeking { ProgressView("Opening video…").controlSize(.small) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var transport: some View {
        HStack(spacing:18) {
            Text(TimeText.format(playback.position)).font(.system(.body,design:.monospaced)).frame(width:124,alignment:.leading)
            Spacer()
            Button { editor.returnToOriginal(); playback.step(-1) } label: { Image(systemName:"backward.frame") }.help("Previous frame (←)")
            Button { editor.togglePlayback() } label: { Image(systemName:(editor.showOutput ? editor.outputPlayer.rate > 0 : playback.playing) ? "pause.fill" : "play.fill").frame(width:18) }.help("Play / pause (Space)")
            Button { editor.returnToOriginal(); playback.step(1) } label: { Image(systemName:"forward.frame") }.help("Next frame (→)")
            Spacer()
            if playback.seeking { ProgressView().controlSize(.small).frame(width:124,alignment:.trailing) }
            else if editor.previewURL != nil {
                Picker("Preview",selection:Binding(get:{editor.showOutput},set:editor.switchPreview)) { Text("Original").tag(false); Text("Output").tag(true) }.pickerStyle(.segmented).frame(width:150)
            } else { Text("Frame preview").font(.caption).foregroundStyle(.secondary).frame(width:124,alignment:.trailing) }
        }.buttonStyle(.borderless).padding(.horizontal,18).frame(height:48)
    }
    private func timeField(_ title:String,text:Binding<String>,value:Double,commit:@escaping (Double?)->Void) -> some View {
        HStack(spacing:8) {
            Text(title).foregroundStyle(.secondary)
            TextField(title,text:text).font(.system(.body,design:.monospaced)).frame(width:125)
                .onSubmit { if let time=TimeText.parse(text.wrappedValue) { commit(time) } else { text.wrappedValue=TimeText.format(value); editor.error="Enter seconds or a time such as 00:01:23.450." } }
        }
    }
    private func inspector(_ details:MediaDetails) -> some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                VStack(alignment:.leading,spacing:12) {
                    Text("Framing").font(.headline)
                    Picker("Crop",selection:$editor.edit.cropPreset) { ForEach(CropPreset.allCases) { Text($0.rawValue).tag($0) } }
                    if editor.edit.cropPreset == .custom {
                        HStack {
                            TextField("Width",value:$editor.edit.customWidth,format:.number).frame(width:72)
                            Text(":").foregroundStyle(.secondary)
                            TextField("Height",value:$editor.edit.customHeight,format:.number).frame(width:72)
                        }.textFieldStyle(.roundedBorder)
                    }
                    if editor.edit.cropPreset != .original { Text("Drag the crop to reframe. Drag its corner to resize.").font(.caption).foregroundStyle(.secondary) }
                    Picker("Resolution",selection:$editor.edit.resolution) { ForEach(Resolution.allCases) { Text($0.rawValue).tag($0) } }
                    let g=editor.edit.geometry(for:details)
                    Text("Output: \(g.outWidth) × \(g.outHeight)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment:.leading,spacing:12) {
                    Text("Video").font(.headline)
                    Picker("Codec",selection:$editor.edit.codec) { ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) } }.disabled(details.hdr && !editor.edit.convertToSDR)
                    if details.hdr { Toggle("Convert to SDR",isOn:$editor.edit.convertToSDR); Text(editor.edit.convertToSDR ? "Tone-mapped for SDR displays." : "HDR is kept with 10-bit H.265.").font(.caption).foregroundStyle(.secondary) }
                    Text("Quality").font(.subheadline)
                    Slider(value:$editor.edit.quality,in:20...95,step:1)
                    HStack { Text("Smaller file"); Spacer(); Text("Higher quality") }.font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment:.leading,spacing:12) {
                    Text("Audio").font(.headline)
                    if !details.audioLabels.isEmpty {
                        if details.audioLabels.count > 1 { Picker("Track",selection:$editor.edit.audioTrack) { ForEach(details.audioLabels.indices,id:\.self) { Text(details.audioLabels[$0]).tag($0) } }.labelsHidden() }
                        Toggle("Mute clip",isOn:$editor.edit.muted)
                    } else { Text("No audio track").foregroundStyle(.secondary).font(.callout) }
                }
                Divider()
                Button { editor.preview() } label: { Label("Preview 5 Seconds",systemImage:"play.rectangle") }.disabled(!editor.canExport).frame(maxWidth:.infinity)
                Text("Render a sample with these settings to check the quality.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.disabled(editor.exporting)
    }
    private var footer: some View {
        HStack(spacing:12) {
            if editor.exporting {
                ProgressView(value:editor.progress).frame(width:140)
                Text("\(editor.jobLabel)… \(Int(editor.progress*100))%").font(.callout).monospacedDigit()
                Button("Cancel") { editor.cancel() }
            } else if let url=editor.lastExport {
                Image(systemName:"checkmark.circle.fill").foregroundStyle(.green)
                Text(url.lastPathComponent).lineLimit(1).font(.callout)
                Button("Show in Finder") { editor.revealExport() }.controlSize(.small)
            } else {
                Text("← →  Step frames     I  Set start     O  Set end").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save As…") { editor.export(saveAs:true) }.disabled(!editor.canExport)
            Button("Export Clip") { editor.export() }.buttonStyle(.borderedProminent).disabled(!editor.canExport)
        }.padding(.horizontal,18).frame(height:60)
    }
}

struct Viewer: View {
    @ObservedObject var editor:Editor
    @ObservedObject var playback:Playback
    var body:some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if editor.showOutput {
                    OutputView(player:editor.outputPlayer)
                } else {
                    let size=playback.details?.displaySize ?? CGSize(width:16,height:9)
                    let scale=min(geometry.size.width/size.width,geometry.size.height/size.height)
                    let display=CGSize(width:size.width*scale,height:size.height*scale)
                    ZStack {
                        VideoSurface(layer:playback.video,rotation:playback.details?.rotation ?? 0,pixelAspect:playback.details?.pixelAspect ?? 1)
                        if editor.edit.cropPreset != .original {
                            CropOverlay(crop:$editor.edit.crop).disabled(editor.exporting)
                        }
                    }.frame(width:display.width,height:display.height)
                }
            }
        }
    }
}
struct VideoSurface:NSViewRepresentable {
    let layer:AVSampleBufferDisplayLayer
    var rotation:Double
    var pixelAspect:Double
    func makeNSView(context:Context) -> Surface { let v=Surface(); v.wantsLayer=true; v.display=layer; v.layer?.addSublayer(layer); return v }
    func updateNSView(_ view:Surface,context:Context) { view.rotation=rotation; view.needsLayout=true }
    final class Surface:NSView {
        var display:AVSampleBufferDisplayLayer?
        var rotation=0.0
        override func layout() {
            super.layout()
            guard let display else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let rotated=abs(sin(rotation * .pi/180)) > 0.5
            display.setAffineTransform(.identity)
            display.bounds=CGRect(origin:.zero,size:rotated ? CGSize(width:bounds.height,height:bounds.width) : bounds.size)
            display.position=CGPoint(x:bounds.midX,y:bounds.midY)
            display.setAffineTransform(CGAffineTransform(rotationAngle:-rotation * .pi/180))
            CATransaction.commit()
        }
    }
}
struct OutputView:NSViewRepresentable {
    let player:AVPlayer
    func makeNSView(context:Context) -> AVPlayerView { let v=AVPlayerView(); v.player=player; v.controlsStyle = .floating; return v }
    func updateNSView(_ view:AVPlayerView,context:Context) { view.player=player }
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
