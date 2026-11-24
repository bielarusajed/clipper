import SwiftUI

struct SubtitleSettingsView:View {
    @ObservedObject var editor:Editor
    @ObservedObject var subtitles:SubtitleController
    let details:MediaDetails
    @State private var styling=false
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            HStack {
                Text("Subtitles").font(.system(size:11,weight:.semibold)).foregroundStyle(C1.secondary)
                Spacer()
                Button { styling.toggle() } label: { Image(systemName:"textformat").frame(width:23,height:21) }
                    .buttonStyle(.borderless).help("Subtitle style").accessibilityLabel("Subtitle style")
                    .popover(isPresented:$styling,arrowEdge:.trailing) { stylePopover }
                Toggle("Burn in subtitles",isOn:$subtitles.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }.padding(.horizontal,5)
            C1Group {
                VStack(alignment:.leading,spacing:8) {
                    if !subtitles.tracks.isEmpty {
                        Picker("Subtitle source",selection:$subtitles.sourceKind) {
                            ForEach(SubtitleSource.allCases,id:\.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).controlSize(.small)
                    }
                    if subtitles.sourceKind == .container && !subtitles.tracks.isEmpty {
                        if subtitles.tracks.count>1 {
                            Picker("Subtitle track",selection:$subtitles.track) {
                                ForEach(subtitles.tracks) { Text($0.label).tag($0.id) }
                            }.controlSize(.small).c1NeutralControl().frame(minWidth:0,maxWidth:.infinity,alignment:.leading)
                                .help(subtitles.tracks.first { $0.id == subtitles.track }?.label ?? "")
                        } else { Text(subtitles.tracks[0].label).lineLimit(2).foregroundStyle(C1.secondary) }
                    } else {
                        HStack(spacing:5) {
                            if let url=subtitles.external {
                                Text(url.lastPathComponent).lineLimit(1).help("\(url.path)\nAn imported snapshot is kept until the video closes.")
                                Spacer(minLength:0)
                                Button { subtitles.external=nil; subtitles.prepare() } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Clear subtitle file")
                            } else { Text("SRT, WebVTT, ASS or SSA").foregroundStyle(C1.muted); Spacer(minLength:0) }
                            Button(subtitles.external == nil ? "Choose…" : "Change…") { if let url=subtitles.chooseFile() { editor.importSubtitles(url) } }.controlSize(.small).c1NeutralControl()
                        }
                    }
                    if subtitles.scanning || subtitles.preparing { HStack { ProgressView().controlSize(.mini); Text("Preparing subtitles…") } }
                    if let message=subtitles.message { Text(message).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                    if subtitles.unsupported>0 { Text("\(subtitles.unsupported) unsupported container track(s). Bitmap subtitles are not supported.").foregroundStyle(C1.muted) }
                    if subtitles.enabled && details.hdr && !editor.edit.convertToSDR {
                        Text("Burned-in subtitles need Convert to SDR for HDR videos.").fixedSize(horizontal:false,vertical:true)
                        Button("Convert to SDR") { editor.setConvertToSDR(true) }.controlSize(.small).c1NeutralControl()
                    }
                    if subtitles.enabled,subtitles.render != nil {
                        Text(subtitles.styled && !subtitles.overrideStyle ? "Authored style · source coordinates" : "Common style · output coordinates").foregroundStyle(C1.muted)
                    }
                }.font(.system(size:10)).padding(10)
            }
        }
        .onChange(of:subtitles.enabled) { _,enabled in
            editor.invalidatePreview()
            if enabled && subtitles.render == nil { subtitles.prepare() }
        }
        .onChange(of:subtitles.external) { _,_ in editor.invalidatePreview() }
        .onChange(of:subtitles.sourceKind) { _,_ in changedSource() }
        .onChange(of:subtitles.track) { _,_ in changedSource() }
        .onChange(of:subtitles.style) { _,_ in changedStyle() }
        .onChange(of:subtitles.overrideStyle) { _,_ in changedStyle() }

    }
    private func changedSource() { editor.invalidatePreview(); subtitles.sourceSelectionChanged() }
    private func changedStyle() { editor.invalidatePreview(); subtitles.rebuild(details:details,edit:editor.edit) }
    private var stylePopover:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Subtitle style").font(.headline)
            if subtitles.styled {
                Toggle("Override authored style",isOn:$subtitles.overrideStyle)
                Text("Override removes positioning, animation, karaoke and colors, and places dialogue inside the output crop. Drawings and hidden placeholders are omitted. Bold, italic and underline remain.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            VStack(alignment:.leading,spacing:10) {
                Picker("Font",selection:$subtitles.style.font) {
                    ForEach(["Helvetica Neue","Arial","Avenir Next","Verdana"].filter { NSFontManager.shared.availableFontFamilies.contains($0) },id:\.self) { Text($0).tag($0) }
                }
                slider("Size",value:$subtitles.style.size,range:2...10,suffix:"% of short edge")
                HStack {
                    ColorPicker("Text",selection:color($subtitles.style.color),supportsOpacity:false)
                    ColorPicker("Edge",selection:color($subtitles.style.outlineColor),supportsOpacity:false)
                }
                Toggle("Solid background box",isOn:$subtitles.style.box)
                slider(subtitles.style.box ? "Box padding" : "Outline",value:$subtitles.style.outline,range:0...5,suffix:"")
                slider("Shadow",value:$subtitles.style.shadow,range:0...5,suffix:"")
                Picker("Placement",selection:$subtitles.style.top) { Text("Bottom").tag(false); Text("Top").tag(true) }.pickerStyle(.segmented)
                slider("Vertical margin",value:$subtitles.style.margin,range:0...20,suffix:"%")
                slider("Side margins",value:$subtitles.style.sideMargin,range:0...20,suffix:"%")
            }.disabled(subtitles.styled && !subtitles.overrideStyle)
            Text("WebVTT cue positioning and CSS are not retained. Use UTF-8 or UTF-16 files. Colors use RGB in all views.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.controlSize(.small).padding(16).frame(width:300).disabled(editor.exporting)
    }
    private func slider(_ title:String,value:Binding<Double>,range:ClosedRange<Double>,suffix:String)->some View {
        VStack(spacing:3) {
            HStack { Text(title); Spacer(); Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(1)))) \(suffix)").foregroundStyle(.secondary) }
            Slider(value:value,in:range,step:0.5)
        }
    }
    private func color(_ hex:Binding<String>)->Binding<Color> {
        Binding(get:{
            let value=UInt64(hex.wrappedValue,radix:16) ?? 0xFFFFFF
            return Color(red:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255)
        },set:{ c in
            guard let rgb=NSColor(c).usingColorSpace(.sRGB) else { return }
            hex.wrappedValue=String(format:"%02X%02X%02X",Int((rgb.redComponent*255).rounded()),Int((rgb.greenComponent*255).rounded()),Int((rgb.blueComponent*255).rounded()))
        })
    }
}
