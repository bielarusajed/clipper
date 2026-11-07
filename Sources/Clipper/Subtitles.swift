import AppKit
import CMedia
import Combine

struct SubtitleTrack: Identifiable, Equatable {
    let id:Int
    let label:String
    let styled:Bool
    let isDefault:Bool
}
struct SubtitleStyle: Equatable {
    var font="Helvetica Neue"
    var size=5.0
    var color="FFFFFF"
    var outlineColor="000000"
    var outline=2.0
    var shadow=1.0
    var box=false
    var top=false
    var margin=5.0
    var sideMargin=5.0
}
enum SubtitleSource:String,CaseIterable { case container="Container", external="External" }

/// Each job owns a directory. Async readers retain it, so replacement never deletes files in use.
final class SubtitleDirectory: @unchecked Sendable {
    let url:URL
    init() throws {
        url=FileManager.default.temporaryDirectory.appendingPathComponent("Clipper-Subtitles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:url.appendingPathComponent("fonts"),withIntermediateDirectories:true)
    }
    deinit { try? FileManager.default.removeItem(at:url) }
}
final class RenderSubtitles: @unchecked Sendable {
    let directory:SubtitleDirectory
    let file:URL
    let zero:Double
    let preserve:Bool
    let identity=UUID()
    var fonts:URL { directory.url.appendingPathComponent("fonts") }
    init(directory:SubtitleDirectory,text:String,zero:Double,preserve:Bool) throws {
        self.directory=directory; self.zero=zero; self.preserve=preserve
        file=directory.url.appendingPathComponent("render-\(identity).ass")
        try text.write(to:file,atomically:true,encoding:.utf8)
    }
    deinit { try? FileManager.default.removeItem(at:file) }
    var filter:String {
        func escape(_ value:String)->String {
            // Two levels: filter option parser, then filter graph parser.
            let option=value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"'",with:"\\'").replacingOccurrences(of:":",with:"\\:")
            return option.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"'",with:"\\'").replacingOccurrences(of:",",with:"\\,").replacingOccurrences(of:"[",with:"\\[").replacingOccurrences(of:"]",with:"\\]").replacingOccurrences(of:";",with:"\\;")
        }
        return "ass=filename=\(escape(file.path)):fontsdir=\(escape(fonts.path)):shaping=complex"
    }
    func milliseconds(frame:FramePoint?,relativeTime:Double,origin:Double)->Int64 {
        if let frame {
            let tb=Double(frame.timeBaseNum)/Double(frame.timeBaseDen)
            return Int64((Double(Int64((Double(frame.pts)-zero/tb).rounded(.towardZero)))*tb*1000).rounded(.towardZero))
        }
        return Int64(((relativeTime+origin-zero)*1000).rounded(.towardZero))
    }
}

enum SubtitleComposer {
    static func decode(_ data:Data) throws -> String {
        if data.starts(with:[0xFF,0xFE]) { if let s=String(data:data,encoding:.utf16LittleEndian) { return s.replacingOccurrences(of:"\u{FEFF}",with:"") } }
        if data.starts(with:[0xFE,0xFF]) { if let s=String(data:data,encoding:.utf16BigEndian) { return s.replacingOccurrences(of:"\u{FEFF}",with:"") } }
        if let s=String(data:data,encoding:.utf8) { return s.replacingOccurrences(of:"\u{FEFF}",with:"") }
        throw ExportFailure.message("Save this subtitle file as UTF-8 or UTF-16, then choose it again.")
    }
    /// RGB is interpreted identically in both renderers, including legacy ASS scripts.
    static func rgbScript(_ text:String)->String {
        let regex=try! NSRegularExpression(pattern:"(?im)^YCbCr Matrix:.*$")
        let range=NSRange(text.startIndex...,in:text)
        if regex.firstMatch(in:text,range:range) != nil { return regex.stringByReplacingMatches(in:text,range:range,withTemplate:"YCbCr Matrix: None") }
        return text.replacingOccurrences(of:"[Script Info]",with:"[Script Info]\nYCbCr Matrix: None",options:.caseInsensitive)
    }
    static func dialogue(_ text:String)->String? {
        if text.range(of:#"\\p[1-9][0-9]*"#,options:.regularExpression) != nil { return nil }
        if text.range(of:#"^\{[^}]*(?:\\alpha|\\1a)&HFF&"#,options:[.regularExpression,.caseInsensitive]) != nil { return nil }
        let blocks=try! NSRegularExpression(pattern:#"\{[^}]*\}"#)
        let tags=try! NSRegularExpression(pattern:#"\\([bius])(-?\d+)"#)
        var result=text
        for block in blocks.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
            let raw=(text as NSString).substring(with:block.range)
            let kept=tags.matches(in:raw,range:NSRange(raw.startIndex...,in:raw)).map { match -> String in
                let ns=raw as NSString
                return "\\\(ns.substring(with:match.range(at:1)))\((Int(ns.substring(with:match.range(at:2))) ?? 0) == 0 ? 0 : 1)"
            }.joined()
            result=(result as NSString).replacingCharacters(in:block.range,with:kept.isEmpty ? "" : "{\(kept)}")
        }
        return result.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : result
    }
    static func compose(_ text:String,style:SubtitleStyle,width:Int,height:Int)->String {
        func n(_ x:Double)->String { String(format:"%.2f",locale:Locale(identifier:"en_US_POSIX"),x) }
        func color(_ hex:String)->String {
            let h=hex.count == 6 ? hex : "FFFFFF"
            let chunks=stride(from:0,to:6,by:2).map { String(Array(h)[$0..<$0+2]) }
            return "&H00"+chunks.reversed().joined()
        }
        let font=style.font.replacingOccurrences(of:",",with:"").replacingOccurrences(of:"\n",with:"")
        let unit=Double(min(width,height))/100
        var result="""
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(width)
        PlayResY: \(height)
        LayoutResX: \(width)
        LayoutResY: \(height)
        ScaledBorderAndShadow: yes
        WrapStyle: 0
        YCbCr Matrix: None
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,\(font),\(n(style.size*unit)),\(color(style.color)),\(color(style.color)),\(color(style.outlineColor)),\(color(style.outlineColor)),-1,0,0,0,100,100,0,0,\(style.box ? 3 : 1),\(n(style.outline*unit/5)),\(n(style.shadow*unit/5)),\(style.top ? 8 : 2),\(Int(Double(width)*style.sideMargin/100)),\(Int(Double(width)*style.sideMargin/100)),\(Int(Double(height)*style.margin/100)),1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        var fields=[String](),seen=Set<String>(),inEvents=false
        for line in text.components(separatedBy:.newlines) {
            let trimmed=line.trimmingCharacters(in:.whitespaces)
            if trimmed.hasPrefix("[") { inEvents=trimmed.lowercased()=="[events]"; continue }
            guard inEvents else { continue }
            if trimmed.lowercased().hasPrefix("format:") { fields=trimmed.dropFirst(7).split(separator:",").map { $0.trimmingCharacters(in:.whitespaces).lowercased() }; continue }
            guard trimmed.lowercased().hasPrefix("dialogue:"), let textIndex=fields.firstIndex(of:"text") else { continue }
            let values=trimmed.dropFirst(9).split(separator:",",maxSplits:textIndex,omittingEmptySubsequences:false).map(String.init)
            func value(_ key:String)->String { guard let i=fields.firstIndex(of:key),i<values.count else { return "" }; return values[i].trimmingCharacters(in:.whitespaces) }
            guard let t=dialogue(value("text")), !value("start").isEmpty, !value("end").isEmpty else { continue }
            let key=value("start")+"|"+value("end")+"|"+t
            guard seen.insert(key).inserted else { continue }
            result += "Dialogue: \(value("layer").isEmpty ? "0" : value("layer")),\(value("start")),\(value("end")),Default,,0,0,0,,\(t)\n"
        }
        return result
    }
}

/// Cancellable helper, with file-backed stderr so large extractions cannot deadlock a pipe.
final class SubtitleProcess: @unchecked Sendable {
    private let lock=NSLock()
    private var process:Process?
    private var cancelled=false
    func cancel() { lock.withLock { cancelled=true; if process?.isRunning == true { process?.terminate() } } }
    static var executable:URL {
        let bundled=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        return FileManager.default.isExecutableFile(atPath:bundled.path) ? bundled : URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/media/bin/ffmpeg")
    }
    func run(_ args:[String],directory:URL) throws {
        let p=Process(),log=directory.appendingPathComponent("extract-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath:log.path,contents:nil)
        let handle=try FileHandle(forWritingTo:log); defer { try? handle.close(); try? FileManager.default.removeItem(at:log) }
        p.executableURL=Self.executable; p.arguments=["-hide_banner","-nostdin","-loglevel","error","-y"]+args
        p.standardOutput=FileHandle.nullDevice; p.standardError=handle
        try lock.withLock { if cancelled { throw CancellationError() }; process=p; try p.run() }
        p.waitUntilExit()
        try lock.withLock { process=nil; if cancelled { throw CancellationError() } }
        if p.terminationStatus != 0 {
            let message=(try? String(contentsOf:log,encoding:.utf8)) ?? "Could not read this subtitle file."
            throw ExportFailure.message(String(message.suffix(2000)))
        }
    }
}

@MainActor final class SubtitleController: ObservableObject {
    @Published var enabled=false
    @Published var sourceKind=SubtitleSource.external
    @Published var track=0
    @Published var external:URL? {
        didSet { if external != oldValue { discardExternalSnapshot() } }
    }
    @Published var overrideStyle=false
    @Published var style=SubtitleStyle()
    @Published private(set) var tracks=[SubtitleTrack]()
    @Published private(set) var unsupported=0
    @Published private(set) var scanning=false
    @Published private(set) var preparing=false
    @Published private(set) var message:String?
    @Published private(set) var render:RenderSubtitles?
    private var directory:SubtitleDirectory?
    // The imported text belongs to the source session, not to the active render job.
    // Switching tracks can cancel conversion without losing the original file contents.
    private var externalSnapshot:Task<String,Error>?
    private var prepared:String?
    private var preparedStyled=false
    private var preparedZero=0.0
    private var renderedText:String?
    private struct Selection:Equatable { let kind:SubtitleSource; let track:Int; let file:URL? }
    private var selection:Selection { Selection(kind:sourceKind,track:sourceKind == .container ? track : 0,file:sourceKind == .external ? external : nil) }
    private var preparationSelection:Selection?
    private var job:SubtitleProcess?
    private var task:Task<Void,Never>?
    private var epoch=UUID()
    private var video:URL?
    private var externalZero=0.0
    private var size=CGSize(width:1920,height:1080)
    var styled:Bool { sourceKind == .external ? ["ass","ssa"].contains(external?.pathExtension.lowercased() ?? "") : tracks.first(where:{$0.id==track})?.styled == true }
    var ready:Bool { !enabled || (render != nil && !scanning && !preparing && message == nil) }
    func reset() {
        epoch=UUID(); task?.cancel(); task=nil; job?.cancel(); job=nil
        discardExternalSnapshot()
        enabled=false; tracks=[]; unsupported=0; external=nil; render=nil; renderedText=nil; preparationSelection=nil; prepared=nil; directory=nil; video=nil
        scanning=false; preparing=false; message=nil; sourceKind = .external; overrideStyle=false
    }
    func open(_ video:URL,details:MediaDetails,timelineOffset:Double=0) {
        reset(); self.video=video; externalZero=details.origin-timelineOffset; scanning=true
        let token=epoch
        task=Task { [weak self] in
            do {
                let dir=try SubtitleDirectory()
                let catalog=await Task.detached { () -> ([SubtitleTrack],Int) in
                    guard let c=clip_subtitle_catalog(video.path,dir.url.appendingPathComponent("fonts").path) else { return ([],0) }
                    defer { clip_subtitle_catalog_free(c) }
                    return ((0..<clip_subtitle_count(c)).map { SubtitleTrack(id:Int(clip_subtitle_stream(c,$0)),label:String(cString:clip_subtitle_label(c,$0)),styled:clip_subtitle_styled(c,$0) != 0,isDefault:clip_subtitle_default(c,$0) != 0) },Int(clip_subtitle_unsupported(c)))
                }.value
                guard let self,self.epoch==token else { return }
                self.directory=dir; self.tracks=catalog.0; self.unsupported=catalog.1; self.scanning=false
                if self.external == nil, let first=self.tracks.first(where:{$0.isDefault}) ?? self.tracks.first { self.track=first.id; self.sourceKind = .container }
                if self.enabled || self.external != nil { self.prepare() }
            } catch { if let self,self.epoch==token { self.scanning=false; self.message=error.localizedDescription } }
        }
    }
    func chooseFile() -> URL? {
        let panel=NSOpenPanel(); panel.allowsMultipleSelection=false; panel.canChooseDirectories=false
        panel.message="Choose UTF-8 or UTF-16 SRT, WebVTT, ASS or SSA subtitles."
        return panel.runModal() == .OK ? panel.url : nil
    }
    func importExternal(_ file:URL) {
        discardExternalSnapshot() // Reimport the same path only on an explicit user action.
        external=file; sourceKind = .external
        _=snapshot(for:file)
        prepare()
    }
    private func discardExternalSnapshot() {
        externalSnapshot?.cancel(); externalSnapshot=nil
    }
    private func snapshot(for file:URL) -> Task<String,Error> {
        if let externalSnapshot { return externalSnapshot }
        let task=Task.detached(priority:.userInitiated) { () throws -> String in
            try Task.checkCancellation()
            guard ["srt","vtt","ass","ssa"].contains(file.pathExtension.lowercased()) else { throw ExportFailure.message("Unsupported subtitles. Choose SRT, WebVTT, ASS or SSA; bitmap subtitles cannot be burned in.") }
            guard let bytes=try? Data(contentsOf:file),bytes.count<=32*1024*1024 else { throw ExportFailure.message("The subtitle file is missing, unreadable or larger than 32 MB. Choose it again.") }
            let text=try SubtitleComposer.decode(bytes)
            try Task.checkCancellation()
            return text
        }
        externalSnapshot=task
        return task
    }
    /// Catalog defaults and disabled track changes must not start a full-file extraction.
    /// Keep an explicit file import already preparing the same selection.
    func sourceSelectionChanged() {
        guard !scanning else { return }
        if !enabled {
            if preparationSelection != selection { discardPreparation() }
        } else if !preparing || preparationSelection != selection {
            prepare()
        }
    }
    private func discardPreparation() {
        job?.cancel(); task?.cancel(); epoch=UUID()
        render=nil; renderedText=nil; prepared=nil; preparationSelection=nil; message=nil; preparing=false
    }
    func prepare() {
        guard !scanning else { return }
        discardPreparation()
        let token=epoch
        preparationSelection=selection
        guard let video, let dir=directory else { return }
        let selected=sourceKind, file=external, styled=self.styled, zero=sourceKind == .external ? externalZero : 0, stream=track
        guard selected == .container || file != nil else { message=enabled ? "Choose a subtitle file." : nil; return }
        let snapshot=selected == .external ? file.map { self.snapshot(for:$0) } : nil
        preparing=true
        let job=SubtitleProcess(); self.job=job
        task=Task { [weak self] in
            do {
                let text=try await Task.detached { () async throws -> String in
                    let output=dir.url.appendingPathComponent("prepared-\(token).ass")
                    defer { try? FileManager.default.removeItem(at:output) }
                    if selected == .external, let file {
                        guard let snapshot else { throw ExportFailure.message("Choose a subtitle file.") }
                        let text=try await snapshot.value
                        if styled {
                            try text.write(to:output,atomically:true,encoding:.utf8)
                        } else {
                            let input=dir.url.appendingPathComponent("input-\(token).\(file.pathExtension.lowercased())")
                            defer { try? FileManager.default.removeItem(at:input) }
                            try text.write(to:input,atomically:true,encoding:.utf8)
                            try job.run(["-copyts","-f",file.pathExtension.lowercased() == "srt" ? "srt" : "webvtt","-i",input.path,"-map","0:s:0","-c:s","ass","-f","ass",output.path],directory:dir.url)
                        }
                    } else {
                        try job.run(["-copyts","-i",video.path,"-map","0:\(stream)","-c:s","ass","-f","ass",output.path],directory:dir.url)
                    }
                    guard let r=clip_subtitles_open(output.path,dir.url.appendingPathComponent("fonts").path) else { throw ExportFailure.message("Could not parse these subtitles.") }
                    let count=clip_subtitles_events(r); clip_subtitles_free(r)
                    guard count>0 else { throw ExportFailure.message("No renderable subtitle cues found.") }
                    return try String(contentsOf:output,encoding:.utf8)
                }.value
                guard let self,self.epoch==token else { return }
                self.prepared=text; self.preparedStyled=styled; self.preparedZero=zero; self.preparing=false
                self.rebuild()
            } catch { guard let self,self.epoch==token else { return }; self.preparing=false; self.message=error.localizedDescription }
        }
    }
    func rebuild(details:MediaDetails?=nil,edit:EditSettings?=nil) {
        if let details,let edit { let g=edit.geometry(for:details); size=CGSize(width:g.outWidth,height:g.outHeight) }
        guard let text=prepared,let directory else { return }
        do {
            let preserve=preparedStyled && !overrideStyle
            let composed=preserve ? SubtitleComposer.rgbScript(text) : SubtitleComposer.compose(text,style:style,width:Int(size.width),height:Int(size.height))
            if let render, renderedText==composed, render.preserve==preserve, render.zero==preparedZero { return }
            let asset=try RenderSubtitles(directory:directory,text:composed,zero:preparedZero,preserve:preserve)
            if !preserve && !composed.contains("Dialogue:") { throw ExportFailure.message("No dialogue remains after overriding this script. Turn off Override authored style to keep drawings.") }
            message=nil; renderedText=composed; render=asset
        } catch { render=nil; message=error.localizedDescription }
    }
}
