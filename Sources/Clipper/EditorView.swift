import SwiftUI
import AVKit

struct EditorView:View {
    @ObservedObject var editor:Editor
    @ObservedObject var playback:Playback
    @State private var dropping=false
    @State private var startText=""
    @State private var endText=""
    @State private var ratioWidth="16"
    @State private var ratioHeight="9"
    @State private var qualityGesture:UUID?
    @State private var qualityDragging=false
    private enum Field:Hashable { case start, end, width, height }
    @FocusState private var focusedField:Field?
    @State private var headerLayout=WindowHeaderLayout()
    @State private var availableWindowSize=CGSize(width:CGFloat.infinity,height:CGFloat.infinity)

    var body:some View {
        ZStack(alignment:.topLeading) {
            Group {
                if editor.source != nil {
                    HStack(spacing:EditorWindowLayout.spacing) {
                        sidebar.frame(width:EditorWindowLayout.sidebarWidth).modifier(GlassPanel.windowIsland)
                        VStack(spacing:EditorWindowLayout.spacing) {
                            Viewer(editor:editor,playback:playback).frame(maxWidth:.infinity,maxHeight:.infinity)
                            timelineDeck.modifier(GlassPanel.windowIsland)
                        }
                    }.padding(EditorWindowLayout.inset)
                } else { emptyState }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            if editor.source == nil, let controls=headerLayout.controls {
                RoundedRectangle(cornerRadius:15).fill(.ultraThinMaterial)
                    .frame(width:controls.width+20,height:controls.height+24)
                    .offset(x:controls.minX-10,y:controls.minY-12).allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth:availableWindowSize.width,maxHeight:availableWindowSize.height)
        .background(WindowMaterial().ignoresSafeArea().allowsHitTesting(false))
        .foregroundStyle(C1.ink)
        .tint(C1.blue)
        .background(EditorWindow(source:editor.source,videoSize:windowVideoSize,onAvailableSize:{ size in
            if availableWindowSize != size { availableWindowSize=size }
        },onHeaderLayout:{ layout in
            if headerLayout != layout { headerLayout=layout }
        }).frame(width:0,height:0))
        .background(WindowPasteHandler(editor:editor).frame(width:0,height:0))
        .overlay {
            if dropping { RoundedRectangle(cornerRadius:10).stroke(C1.blue,lineWidth:3).padding(4).allowsHitTesting(false) }
        }
        .onDrop(of:[.fileURL],isTargeted:$dropping) { providers in
            guard !editor.exporting, let provider=providers.first else { return false }
            _=provider.loadObject(ofClass:URL.self) { url,_ in
                if let url { Task { @MainActor in editor.open(url) } }
            }
            return true
        }
        .onAppear {
            startText=TimeText.format(editor.displayTime(editor.inTime)); endText=TimeText.format(editor.displayTime(editor.end?.time ?? 0))
            syncRatio()
        }
        .onChange(of:focusedField) { old,new in
            // Invalidate command presentation; routing always reads the actual responder.
            editor.objectWillChange.send()
            if old == .width || old == .height { commitRatio() }
            if old == .start { startText=TimeText.format(editor.displayTime(editor.inTime)) }
            if old == .end { endText=TimeText.format(editor.displayTime(editor.end?.time ?? 0)) }
        }
        .onReceive(NotificationCenter.default.publisher(for:NSControl.textDidBeginEditingNotification)) { _ in editor.objectWillChange.send() }
        .onReceive(NotificationCenter.default.publisher(for:NSControl.textDidEndEditingNotification)) { _ in editor.objectWillChange.send() }
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.didBecomeKeyNotification)) { _ in editor.objectWillChange.send() }
        .onChange(of:editor.edit) { _,_ in if focusedField != .width && focusedField != .height { syncRatio() } }
        .onChange(of:editor.start) { _,_ in startText=TimeText.format(editor.displayTime(editor.inTime)) }
        .onChange(of:editor.end) { _,value in endText=TimeText.format(editor.displayTime(value?.time ?? 0)) }
        .onChange(of:editor.timeDisplayOffset) { _,_ in
            startText=TimeText.format(editor.displayTime(editor.inTime))
            endText=TimeText.format(editor.displayTime(editor.end?.time ?? 0))
        }
        .onChange(of:editor.boundaryRevision) { _,_ in
            if editor.lastBoundaryIsStart { startText=TimeText.format(editor.displayTime(editor.inTime)) }
            else { endText=TimeText.format(editor.displayTime(editor.end?.time ?? 0)) }
        }
        .background(URLImportPresenter(editor:editor).frame(width:0,height:0))
        .alert("Clipper",isPresented:Binding(get:{editor.error != nil || playback.error != nil},set:{if !$0 {editor.error=nil;playback.error=nil}})) {
            Button("OK") { editor.error=nil; playback.error=nil }
        } message: { Text(editor.error ?? playback.error ?? "") }
    }

    private func setting<Value>(_ key:WritableKeyPath<EditSettings,Value>,_ name:String)->Binding<Value> {
        Binding(get:{ editor.edit[keyPath:key] },set:{ value in editor.updateSettings(name) { $0[keyPath:key]=value } })
    }
    private func syncRatio() {
        ratioWidth=editor.edit.customWidth.formatted(.number.grouping(.never))
        ratioHeight=editor.edit.customHeight.formatted(.number.grouping(.never))
    }
    private func commitRatio() {
        guard editor.edit.cropPreset == .custom else { syncRatio(); return }
        let style=FloatingPointFormatStyle<Double>.number
        guard let width=try? Double(ratioWidth,format:style), let height=try? Double(ratioHeight,format:style),
              width.isFinite, height.isFinite, width>0, height>0, (width/height).isFinite, width/height>0 else { syncRatio(); return }
        editor.updateSettings("Crop Ratio") { $0.customWidth=width; $0.customHeight=height }
        syncRatio()
    }

    private var windowVideoSize:CGSize? {
        guard !editor.loading, let details=playback.details else { return nil }
        if editor.previewMode == .original { return details.displaySize }
        let geometry=editor.edit.geometry(for:details)
        return CGSize(width:geometry.outWidth,height:geometry.outHeight)
    }

    private var sidebar:some View {
        VStack(spacing:0) {
            sourceHeader.padding(.horizontal,EditorWindowLayout.headerPadding).padding(.bottom,16)
            ScrollView {
                VStack(spacing:16) {
                    if let details=playback.details {
                        section("Clip",detail:String(format:"%.3f s output",editor.outputDuration)) {
                            C1Group {
                                boundaryRow("Start",isStart:true,text:$startText,value:editor.inTime)
                                rowDivider
                                boundaryRow("End",isStart:false,text:$endText,value:editor.end?.time ?? 0)
                                rowDivider
                                HStack {
                                    Text("Speed")
                                    Spacer(minLength:4)
                                    Picker("Clip speed",selection:setting(\.speed,"Speed")) {
                                        ForEach(ClipSpeed.allCases) { Text($0 == .normal ? "1× (Normal)" : $0.label).tag($0) }
                                    }.labelsHidden().fixedSize().c1NeutralControl()
                                        .help("Change playback and export speed. Audio keeps its pitch; Start and End use source time.")
                                }.font(.system(size:12)).controlSize(.small).padding(.horizontal,10).frame(height:36)
                                rowDivider
                                HStack {
                                    Text(editor.importTimeNote ?? "Snap to source frames").help(editor.importTimeNote ?? "Snap to source frames").lineLimit(1)
                                }.font(.system(size:10)).foregroundStyle(C1.muted).padding(.horizontal,10).frame(height:27)
                            }
                        }
                        framing(details)
                        videoSettings(details)
                        if !details.audioLabels.isEmpty { audioSettings(details) }
                        SubtitleSettingsView(editor:editor,subtitles:editor.subtitles,details:details)
                    } else {
                        VStack(spacing:12) {
                            if editor.loading { ProgressView().controlSize(.small); Text("Opening video…") }
                            else { Text("This video could not be opened.") }
                        }.font(.callout).foregroundStyle(C1.secondary).frame(maxWidth:.infinity).padding(.top,32)
                    }
                }.padding(.horizontal,14).padding(.bottom,16)
            }.disabled(editor.loading || editor.exporting)
            exportFooter
        }
    }

    private var sourceHeader:some View {
        HStack(spacing:EditorWindowLayout.headerSpacing) {
            Color.clear.frame(width:headerLayout.reserve,height:headerLayout.height)
            VStack(alignment:.leading,spacing:4) {
                Text(editor.source?.lastPathComponent ?? "Video").font(.system(size:11,weight:.semibold)).lineLimit(1).help(editor.source?.lastPathComponent ?? "Video")
                if let details=playback.details {
                    Text("\(details.codec.uppercased()) · \(Int(details.displaySize.width))×\(Int(details.displaySize.height)) · \(details.fps.formatted(.number.precision(.fractionLength(0...2)))) fps")
                        .font(.system(size:9)).foregroundStyle(C1.secondary).lineLimit(1)
                } else { Text("Reading video").font(.system(size:10)).foregroundStyle(C1.muted) }
            }.frame(maxWidth:.infinity,alignment:.leading).background(WindowDragRegion())
            Button { editor.close() } label: { Image(systemName:"xmark").font(.system(size:8,weight:.semibold)).frame(width:19,height:19).background(C1.line,in:Circle()) }
                .buttonStyle(.plain).foregroundStyle(C1.secondary).disabled(editor.exporting)
                .help("Close video and return to the empty state").accessibilityLabel("Close video")
        }
        .frame(height:headerLayout.height)
    }

    private func section<Content:View>(_ title:String,detail:String?=nil,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:7) {
            HStack {
                Text(title).font(.system(size:11,weight:.semibold)).foregroundStyle(C1.secondary)
                Spacer()
                if let detail { Text(detail).font(.system(size:10)).foregroundStyle(C1.muted).monospacedDigit() }
            }.padding(.horizontal,5)
            content()
        }
    }
    private var rowDivider:some View { C1.line.frame(height:0.5).padding(.horizontal,10) }

    private func boundaryRow(_ title:String,isStart:Bool,text:Binding<String>,value:Double)->some View {
        HStack(spacing:4) {
            Text(title).font(.system(size:12)).frame(maxWidth:.infinity,alignment:.leading)
            nudgeButton(isStart:isStart,direction:-1)
            TextField(title,text:text)
                .font(.system(size:12,weight:.medium).monospacedDigit())
                .textFieldStyle(.plain).multilineTextAlignment(.center)
                .padding(.vertical,5).frame(width:107)
                .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:5))
                .overlay(RoundedRectangle(cornerRadius:5).stroke(C1.line,lineWidth:1))
                .overlay(alignment:.leading) { C1.amber.frame(width:2).padding(.vertical,4) }
                .focused($focusedField,equals:isStart ? .start : .end)
                .onSubmit {
                    guard text.wrappedValue != TimeText.format(editor.displayTime(value)) else { return }
                    if let displayed=TimeText.parse(text.wrappedValue), let t=editor.localTime(displayed) {
                        isStart ? editor.markStart(t) : editor.markEnd(t)
                    }
                    else { text.wrappedValue=TimeText.format(editor.displayTime(value)); editor.error="Enter a time inside the imported video, as seconds or hh:mm:ss.sss." }
                    focusedField=nil
                }
                .help(isStart ? "First included source frame" : "Last included source frame")
            nudgeButton(isStart:isStart,direction:1)
        }.padding(.horizontal,10).frame(height:36)
    }
    private func nudgeButton(isStart:Bool,direction:Int)->some View {
        Button { editor.nudgeBoundary(start:isStart,direction:direction) } label: {
            Image(systemName:direction < 0 ? "chevron.left" : "chevron.right").font(.system(size:8,weight:.medium)).frame(width:15,height:26)
        }.buttonStyle(.plain).foregroundStyle(C1.muted)
            .accessibilityLabel("Move \(isStart ? "start" : "end") one frame \(direction < 0 ? "earlier" : "later")")
    }

    private func framing(_ details:MediaDetails)->some View {
        let g=editor.edit.geometry(for:details)
        return section("Framing",detail:"\(g.outWidth)×\(g.outHeight)") {
            C1Group {
                HStack(spacing:1) {
                    ForEach(CropPreset.allCases) { preset in
                        let selected=editor.edit.cropPreset == preset
                        Button { editor.updateSettings("Crop") { $0.cropPreset=preset } } label: {
                            VStack(spacing:4) {
                                AspectGlyph(ratio:preset.ratio ?? details.displaySize.width/details.displaySize.height,custom:preset == .custom)
                                Text(preset.rawValue).font(.system(size:9))
                            }
                            .frame(maxWidth:.infinity).frame(height:47)
                            .foregroundStyle(selected ? C1.ink : C1.secondary)
                            .background(selected ? Color.primary.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:7))
                            .overlay(RoundedRectangle(cornerRadius:7).stroke(selected ? Color.primary.opacity(0.16) : .clear,lineWidth:1))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Crop to \(preset.rawValue)").accessibilityLabel("Crop \(preset.rawValue)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(.horizontal,5).padding(.top,8).padding(.bottom,7)
                if editor.edit.cropPreset == .custom {
                    HStack(spacing:6) {
                        Text("Ratio").frame(maxWidth:.infinity,alignment:.leading)
                        TextField("Width",text:$ratioWidth).focused($focusedField,equals:.width).onSubmit { commitRatio(); focusedField=nil }.frame(width:57)
                        Text(":").foregroundStyle(C1.muted)
                        TextField("Height",text:$ratioHeight).focused($focusedField,equals:.height).onSubmit { commitRatio(); focusedField=nil }.frame(width:57)
                    }.font(.system(size:11)).padding(.horizontal,10).padding(.bottom,9).textFieldStyle(.roundedBorder)
                }
                rowDivider
                HStack {
                    Text("Resolution")
                    Spacer(minLength:4)
                    Picker("Resolution",selection:setting(\.resolution,"Resolution")) {
                        ForEach(Resolution.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize().c1NeutralControl().frame(maxWidth:154,alignment:.trailing)
                }.font(.system(size:12)).controlSize(.small).padding(.horizontal,10).frame(height:36)
            }
        }
    }

    private func videoSettings(_ details:MediaDetails)->some View {
        section("Video",detail:details.hdr && !editor.edit.convertToSDR ? "MP4 · HDR" : "MP4") {
            C1Group {
                Picker("Codec",selection:Binding(get:{editor.edit.codec},set:{editor.setCodec($0)})) { ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).padding(8)
                    .disabled(details.hdr && !editor.edit.convertToSDR)
                rowDivider
                VStack(spacing:5) {
                    HStack {
                        Text("Quality").font(.system(size:12))
                        Spacer()
                        Text(editor.edit.quality < 55 ? "Smaller file" : editor.edit.quality > 75 ? "Higher quality" : "Balanced").font(.system(size:10)).foregroundStyle(C1.muted)
                    }
                    Slider(value:Binding(get:{editor.edit.quality},set:{ value in
                        guard !qualityDragging || qualityGesture != nil else { return }
                        editor.setQuality(value,gesture:qualityGesture)
                    }),in:20...95,step:1,onEditingChanged:{ editing in
                        qualityDragging=editing
                        if editing { qualityGesture=editor.beginEditGesture("Quality") }
                        else { editor.endEditGesture(qualityGesture); qualityGesture=nil }
                    }).controlSize(.mini).accessibilityLabel("Output quality")
                    HStack { Text("Smaller file"); Spacer(); Text("Higher quality") }.font(.system(size:9)).foregroundStyle(C1.muted)
                }.padding(10)
                if details.hdr {
                    rowDivider
                    Toggle("Convert to SDR",isOn:Binding(get:{editor.edit.convertToSDR},set:{editor.setConvertToSDR($0)})).font(.system(size:11)).toggleStyle(.switch).controlSize(.mini).padding(10)
                }
            }
        }
    }

    private func audioSettings(_ details:MediaDetails)->some View {
        section("Audio") {
            C1Group {
                if details.audioLabels.count > 1 {
                    HStack {
                        Text("Track")
                        Spacer(minLength:4)
                        Picker("Audio track",selection:setting(\.audioTrack,"Audio Track")) {
                            ForEach(details.audioLabels.indices,id:\.self) { Text(details.audioLabels[$0]).tag($0) }
                        }.labelsHidden().fixedSize().c1NeutralControl().frame(maxWidth:170,alignment:.trailing).disabled(playback.seeking)
                    }.font(.system(size:12)).controlSize(.small).padding(.horizontal,10).frame(height:35)
                    rowDivider
                }
                HStack {
                    Text("Exclude audio")
                    Spacer()
                    Toggle("Exclude audio",isOn:setting(\.muted,"Exclude Audio")).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }.font(.system(size:12)).padding(.horizontal,10).frame(height:34)
            }
        }
    }

    private var exportFooter:some View {
        VStack(alignment:.leading,spacing:9) {
            if editor.exporting {
                HStack {
                    Text(editor.jobLabel).font(.system(size:11,weight:.medium))
                    Spacer()
                    Button("Cancel") { editor.cancel() }.font(.system(size:11)).buttonStyle(.plain).foregroundStyle(C1.blue)
                }
                ProgressView(value:editor.progress).controlSize(.small)
                Text("\(Int(editor.progress*100))%").font(.system(size:10)).foregroundStyle(C1.secondary).monospacedDigit()
            } else {
                HStack(spacing:5) {
                    VStack(alignment:.leading,spacing:4) {
                        Text(editor.nextOutputURL?.lastPathComponent ?? "Your clip.mp4").font(.system(size:10,weight:.medium)).lineLimit(1)
                        if let details=playback.details {
                            let g=editor.edit.geometry(for:details)
                            Text("\(g.outWidth)×\(g.outHeight) · \(editor.edit.codec.rawValue)\(editor.edit.muted ? " · No audio" : "")")
                                .font(.system(size:9)).foregroundStyle(C1.muted).monospacedDigit()
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
                HStack(spacing:8) {
                    Button("Preview 5 s") { editor.preview() }.buttonStyle(C1ButtonStyle()).disabled(!editor.canExport)
                    HStack(spacing:0) {
                        Button("Export Clip") { editor.export() }
                            .frame(maxWidth:.infinity,minHeight:34).contentShape(Rectangle())
                        Color.white.opacity(0.25).frame(width:1,height:20)
                        Button { editor.export(saveAs:true) } label: {
                            Image(systemName:"folder").frame(width:30,height:34).contentShape(Rectangle())
                        }.help("Export As… (⇧⌘E)").accessibilityLabel("Export As…")
                    }.buttonStyle(.plain).font(.system(size:12,weight:.medium)).foregroundStyle(.white)
                        .background(LinearGradient(colors:[Color(red:0.16,green:0.53,blue:0.98),C1.blue],startPoint:.top,endPoint:.bottom),in:RoundedRectangle(cornerRadius:8))
                        .overlay(RoundedRectangle(cornerRadius:8).stroke(C1.blue.opacity(0.4),lineWidth:1).allowsHitTesting(false))
                        .opacity(editor.canExport ? 1 : 0.45).disabled(!editor.canExport)
                }
                ExportHandoffView(clip:editor.exportedClip)
            }
        }.padding(.horizontal,14).padding(.top,12).padding(.bottom,14)
            .background(C1.line.frame(height:1),alignment:.top)
    }

    private var timelineDeck:some View {
        VStack(spacing:EditorWindowLayout.timelineSpacing) {
            HStack(spacing:9) {
                Button { editor.seek(editor.inTime) } label: { Image(systemName:"backward.end.fill") }.help("Go to start")
                Button { editor.stepFrame(-1) } label: { Image(systemName:"chevron.left") }.help("Previous frame (←)")
                Button { editor.togglePlayback() } label: {
                    Image(systemName:editor.isPlaying ? "pause.fill" : "play.fill").frame(width:27,height:24).background(C1.blue.opacity(0.07),in:RoundedRectangle(cornerRadius:5))
                }.help("Play / pause (Space)")
                Button { editor.stepFrame(1) } label: { Image(systemName:"chevron.right") }.help("Next frame (→)")
                Text(TimeText.format(editor.displayTime(editor.displayedPosition))).font(.system(size:12,weight:.semibold).monospacedDigit()).foregroundStyle(C1.ink).padding(.leading,3)
                if playback.seeking { ProgressView().controlSize(.mini) }
                Spacer()
                if editor.previewMode == .original && editor.loopEnabled && playback.loopGap {
                    Text("Rewind gap").font(.system(size:10)).foregroundStyle(C1.amber)
                        .help("Playback had to rewind at a committed boundary. This pause is playback overhead, not part of your clip.")
                }
                Button { editor.toggleLoop() } label: {
                    Image(systemName:"repeat").frame(width:24,height:24)
                        .foregroundStyle(editor.loopEnabled ? C1.blue : C1.secondary)
                        .background(editor.loopEnabled ? C1.blue.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:5))
                }.help(editor.previewMode == .original ? "Loop selection (⌘L)" : "Loop encoded sample (⌘L)")
                    .accessibilityLabel("Loop selection").accessibilityValue(editor.loopEnabled ? "On" : "Off")
                Button { editor.auditionCut() } label: {
                    Image(systemName:"play.end").frame(width:24,height:24)
                        .foregroundStyle(editor.auditioning && editor.isPlaying ? C1.blue : C1.secondary)
                }.help(editor.auditionHelp).accessibilityLabel("Audition cut").disabled(!editor.canAudition)
            }.buttonStyle(.borderless).font(.system(size:11)).foregroundStyle(C1.secondary).frame(height:EditorWindowLayout.transportHeight)
            Timeline(editor:editor,playback:playback).frame(height:EditorWindowLayout.timelineHeight)

        }.padding(.horizontal,18).padding(.vertical,EditorWindowLayout.timelinePadding)

            .disabled(editor.loading || editor.exporting)
    }

    private var emptyState:some View {
        ZStack {
            Color.clear
            VStack(spacing:15) {
                Image(systemName:"film.stack").font(.system(size:34,weight:.light)).foregroundStyle(C1.blue)
                    .frame(width:72,height:72).modifier(GlassPanel(radius:20))
                Text("Clip a moment from a video").font(.system(size:20,weight:.semibold))
                Text("Drop or paste a video file,\nor paste a URL to download.").multilineTextAlignment(.center).font(.system(size:12)).foregroundStyle(C1.secondary).lineSpacing(4)
                Button("Open Video…") { editor.openPanel() }.buttonStyle(C1ButtonStyle(primary:true)).frame(width:146)
                Button("Import URL…") { editor.showURLImporter() }.buttonStyle(C1ButtonStyle()).frame(width:146)
                Text("MP4, MOV, WebM, MKV and AVI").font(.system(size:10)).foregroundStyle(C1.muted).padding(.top,2)
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
