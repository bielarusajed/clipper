import SwiftUI

struct URLImportView:View {
    @ObservedObject var importer:URLImport
    let open:(TemporaryImport)->Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var urlFocused:Bool

    private var canDownload:Bool {
        !importer.downloadRequested && !importer.cancelling && !importer.urlText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }

    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Import URL").font(.system(size:16,weight:.semibold))
            HStack(spacing:10) {
                TextField("Video URL",text:$importer.urlText)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .focused($urlFocused).onSubmit { importer.download(open:open) }
                    .accessibilityLabel("Video URL").disabled(importer.downloadRequested)
                downloadButton
            }
            if importer.formatsVisible, let media=importer.media {
                HStack(spacing:12) {
                    Text(media.title).font(.system(size:12,weight:.medium)).lineLimit(1).help(media.title)
                    Spacer(minLength:0)
                    if let duration=media.duration, duration.isFinite, duration > 0 {
                        Text(TimeText.format(duration)).font(.system(size:11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                formatTable(media)
            }
            if importer.showsStatus {
                HStack(spacing:10) {
                    ProgressView().controlSize(.small)
                    Text(importer.status).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength:0)
                    if let progress=importer.progress { ProgressView(value:progress).frame(width:110) }
                }.accessibilityElement(children:.combine)
            }
            if let error=importer.error {
                ScrollView {
                    Text(error).font(.system(size:12)).foregroundStyle(.red)
                        .textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:90)
            }
            HStack {
                Button(importer.downloadRequested ? "Cancel Download" : "Cancel",role:.cancel) {
                    if importer.downloadRequested { importer.cancel() }
                    else { importer.endPresentation(); dismiss() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if importer.formatsVisible && !importer.downloadRequested {
                    Button("Use default formats") { importer.useDefaultFormats() }
                        .buttonStyle(.plain).font(.system(size:11)).foregroundStyle(C1.blue)
                }
            }
        }
        .padding(20).frame(width:importer.formatsVisible ? 980 : 640)
        .fixedSize(horizontal:false,vertical:true)
        .interactiveDismissDisabled(importer.downloadRequested)
        .onAppear { urlFocused=true }
        .onDisappear { importer.endPresentation() }
        .onChange(of:importer.urlText) { _,_ in importer.urlChanged() }
    }

    private var downloadButton:some View {
        HStack(spacing:0) {
            Button("Download") { importer.download(open:open) }
                .padding(.horizontal,14).frame(height:32).contentShape(Rectangle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canDownload)
            Color.white.opacity(0.25).frame(width:1,height:20)
            Button { importer.showFormats() } label: {
                Image(systemName:"slider.horizontal.3").frame(width:32,height:32).contentShape(Rectangle())
            }.keyboardShortcut(.return,modifiers:.command)
                .help("Choose video and audio formats (⌘↩)").accessibilityLabel("Choose formats")
                .disabled(importer.cancelling || importer.urlText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        }
        .buttonStyle(.plain).font(.system(size:12,weight:.medium)).foregroundStyle(.white)
        .background(LinearGradient(colors:[Color(red:0.16,green:0.53,blue:0.98),C1.blue],startPoint:.top,endPoint:.bottom),in:RoundedRectangle(cornerRadius:8))
        .overlay(RoundedRectangle(cornerRadius:8).stroke(C1.blue.opacity(0.4),lineWidth:1).allowsHitTesting(false))
        .opacity(importer.cancelling || importer.urlText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? 0.45 : 1)
    }

    private func formatTable(_ media:URLMedia)->some View {
        Table(ImportFormatRow.rows(media)) {
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
        .frame(height:330)
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
