import SwiftUI

enum URLImportLayout {
    static let width:CGFloat=760
    static let buttonWidth:CGFloat=200
    static let tableWidth:CGFloat=940
    static let tableHeight:CGFloat=330
    static let compactHeight:CGFloat=120
    static let expandedHeight:CGFloat=compactHeight+18+tableHeight+32
}

struct URLImportView:View {
    @ObservedObject var importer:URLImport
    let open:(TemporaryImport)->Void
    let close:()->Void
    @FocusState private var urlFocused:Bool

    private var canDownload:Bool {
        !importer.downloadRequested && !importer.cancelling && !importer.urlText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }

    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:10) {
                TextField("Video URL",text:$importer.urlText)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .focused($urlFocused).onSubmit { importer.download(open:open) }
                    .accessibilityLabel("Video URL").disabled(importer.downloadRequested)
                downloadButton
            }
            VStack(alignment:.leading,spacing:8) {
                Toggle("Import a rough time range",isOn:$importer.rangeEnabled)
                    .toggleStyle(.checkbox).font(.system(size:12))
                if importer.rangeEnabled {
                    HStack(spacing:8) {
                        Text("Start")
                        TextField("08:00",text:$importer.rangeStart).accessibilityLabel("Rough range start")
                        Text("End")
                        TextField("08:30",text:$importer.rangeEnd).accessibilityLabel("Rough range end")
                    }.font(.system(size:12)).textFieldStyle(.roundedBorder).monospacedDigit()
                    if let duration=importer.media?.duration, duration.isFinite, duration > 0 {
                        Text("Video duration: \(TimeText.format(duration))").font(.system(size:11)).foregroundStyle(.secondary)
                    } else if importer.media != nil {
                        Text("Source duration unavailable. Enter a finite end time.").font(.system(size:11)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing:8) {
                    Toggle("Download subtitles",isOn:$importer.subtitlesEnabled).toggleStyle(.checkbox)
                        .help("Embed every available subtitle language in the imported video. Choose a track under Subtitles in the editor.")
                    if let media=importer.media {
                        let count=media.subtitleOptions().count
                        Text(count == 0 ? "None available" : count == 1 ? "1 language available" : "\(count) languages available")
                            .foregroundStyle(.secondary)
                    }
                }.font(.system(size:12))
            }.disabled(importer.downloadRequested)
            if importer.formatsVisible {
                HStack(spacing:12) {
                    Text(importer.media?.title ?? "Formats").font(.system(size:12,weight:.medium)).lineLimit(1)
                        .help(importer.media?.title ?? "")
                    Spacer(minLength:0)
                    if let duration=importer.media?.duration, duration.isFinite, duration > 0 {
                        Text(TimeText.format(duration)).font(.system(size:11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }.frame(height:18)
                ScrollView(.horizontal) {
                    formatTable(importer.media).frame(width:URLImportLayout.tableWidth)
                }.frame(height:URLImportLayout.tableHeight).scrollIndicators(.visible)
            }
            if let error=importer.error {
                ScrollView {
                    Text(error).font(.system(size:12)).foregroundStyle(.red)
                        .textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:90)
                if importer.canRetryFull {
                    Button("Import full video") { importer.retryFull(open:open) }.disabled(!canDownload)
                }
            }

        }
        .padding(20).frame(width:URLImportLayout.width)
        .fixedSize(horizontal:false,vertical:true)
        .onExitCommand(perform:close)
        .onAppear { urlFocused=true }
        .onChange(of:importer.urlText) { _,_ in importer.urlChanged() }
        .onChange(of:importer.rangeEnabled) { _,_ in importer.rangeToggled() }
    }

    private var buttonLabel:String {
        if importer.cancelling { return "Cancelling…" }
        if importer.showsActivity && !importer.downloadRequested { return "Loading formats…" }
        if importer.downloadRequested {
            if let progress=importer.progress { return "Downloading \(Int(progress*100))%" }
            return importer.media == nil ? "Loading formats…" : importer.rangeEnabled ? "Importing section…" : "Downloading…"
        }
        return "Download"
    }

    private var downloadButton:some View {
        HStack(spacing:0) {
            Button { importer.download(open:open) } label: {
                HStack(spacing:7) {
                    if importer.showsActivity { ProgressView().controlSize(.mini).tint(.white) }
                    Text(buttonLabel).lineLimit(1)
                }
                .frame(width:URLImportLayout.buttonWidth-33,height:32).contentShape(Rectangle())
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canDownload)
            .help(importer.showsActivity ? importer.status : "Download the selected video and audio formats")
            Color.white.opacity(0.25).frame(width:1,height:20)
            if importer.showsActivity {
                Button { importer.cancel() } label: {
                    Image(systemName:"xmark").frame(width:32,height:32).contentShape(Rectangle())
                }.help("Cancel the current operation").accessibilityLabel("Cancel operation").disabled(importer.cancelling)
            } else {
                Button { importer.showFormats() } label: {
                    Image(systemName:"slider.horizontal.3").frame(width:32,height:32).contentShape(Rectangle())
                }.help("Choose video and audio formats (⌘↩)").accessibilityLabel("Choose formats")
                    .disabled(importer.urlText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width:URLImportLayout.buttonWidth)
        .buttonStyle(.plain).font(.system(size:12,weight:.medium)).foregroundStyle(.white)
        .background(LinearGradient(colors:[Color(red:0.16,green:0.53,blue:0.98),C1.blue],startPoint:.top,endPoint:.bottom),in:RoundedRectangle(cornerRadius:8))
        .overlay(RoundedRectangle(cornerRadius:8).stroke(C1.blue.opacity(0.4),lineWidth:1).allowsHitTesting(false))
        .opacity(importer.urlText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? 0.45 : 1)
    }

    private func formatTable(_ media:URLMedia?)->some View {
        Table(media.map(ImportFormatRow.rows) ?? []) {
            TableColumn("Video") { row in
                if row.kind == .best || row.format?.hasVideo == true {
                    radio(selected:importer.video == row.id,label:"Video \(row.accessibleName)") { importer.selectVideo(row.id) }
                }
            }.width(42)
            TableColumn("Audio") { row in
                if row.kind == .best || row.kind == .none || (row.format?.hasAudio == true && row.format?.hasVideo == false) {
                    radio(selected:importer.audio == row.id && !(importer.includesAudio && row.kind != .none),label:"Audio \(row.accessibleName)") {
                        importer.audio=row.id
                    }.disabled(importer.includesAudio && row.kind != .none)
                } else if row.format?.hasAudio == true && importer.video == row.id {
                    radio(selected:!importer.excludesAudio,label:"Audio included in selected video") { importer.audio="best" }
                }
            }.width(42)
            TableColumn("ID") { row in Text(row.format?.id ?? "").monospaced() }.width(min:65,ideal:78,max:110)
            TableColumn("Ext") { row in Text(row.format?.ext ?? "") }.width(38)
            TableColumn("Resolution") { row in Text(row.resolution) }.width(min:100,ideal:115,max:150)
            TableColumn("FPS") { row in Text(row.format?.fpsText ?? "") }.width(34)
            TableColumn("Size") { row in Text(row.format?.sizeText ?? "") }.width(min:62,ideal:70,max:85)
            TableColumn("Video codec") { row in Text(row.format?.videoCodecText ?? "") }.width(min:70,ideal:95,max:125)
            TableColumn("Audio codec") { row in Text(row.format?.audioCodecText ?? "") }.width(min:70,ideal:90,max:120)
            TableColumn("Details") { row in Text(row.format?.detailsText ?? "") }.width(min:95,ideal:130,max:230)
        }
        .font(.system(size:11)).tableStyle(.inset(alternatesRowBackgrounds:true))
        .frame(height:URLImportLayout.tableHeight)
        .disabled(importer.downloadRequested)
    }

    private func radio(selected:Bool,label:String,action:@escaping()->Void)->some View {
        Button(action:action) {
            Image(systemName:selected ? "smallcircle.filled.circle" : "circle")
                .font(.system(size:14)).foregroundStyle(selected ? C1.blue : C1.secondary.opacity(0.65))
                .frame(width:26,height:24).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ImportFormatRow:Identifiable {
    enum Kind { case best, none, format }
    let kind:Kind
    let format:URLMediaFormat?
    var id:String { switch kind { case .best: return "best"; case .none: return "none"; case .format: return format!.id } }
    var resolution:String { switch kind { case .best: return "Best available"; case .none: return "No audio"; case .format: return format!.resolutionText } }
    var accessibleName:String { kind == .format ? format!.label : resolution }
    static func rows(_ media:URLMedia)->[Self] {
        [.init(kind:.best,format:nil),.init(kind:.none,format:nil)]
        + media.formats.reversed().filter { $0.selectable && ($0.hasVideo || $0.hasAudio) }.map { .init(kind:.format,format:$0) }
    }
}
