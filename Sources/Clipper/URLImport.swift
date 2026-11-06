import Foundation

protocol URLImportServicing:Sendable {
    func prepare(status:@escaping @Sendable(String)->Void) async throws -> ImportTools
    func inspect(url:URL,tools:ImportTools) async throws -> URLMedia
    func download(url:URL,media:URLMedia,selector:String,excludeAudio:Bool,tools:ImportTools,
                  progress:@escaping @Sendable(ImportProgress)->Void) async throws -> TemporaryImport
}

struct URLImportService:URLImportServicing {
    func prepare(status:@escaping @Sendable(String)->Void) async throws -> ImportTools {
        try await ManagedImportTools.shared.prepare(status:status)
    }
    func inspect(url:URL,tools:ImportTools) async throws -> URLMedia { try await URLMediaDownload.inspect(url:url,tools:tools) }
    func download(url:URL,media:URLMedia,selector:String,excludeAudio:Bool,tools:ImportTools,
                  progress:@escaping @Sendable(ImportProgress)->Void) async throws -> TemporaryImport {
        try await URLMediaDownload.download(url:url,media:media,selector:selector,excludeAudio:excludeAudio,tools:tools,progress:progress)
    }
}

@MainActor final class URLImport:ObservableObject {
    @Published var urlText=""
    @Published private(set) var media:URLMedia?
    @Published var video="best"
    @Published var audio="best"
    @Published private(set) var formatsVisible=false
    @Published private(set) var busy=false
    @Published private(set) var downloadRequested=false
    @Published private(set) var cancelling=false
    @Published private(set) var status=""
    @Published private(set) var progress:Double?
    @Published private(set) var error:String?
    private let service:any URLImportServicing
    private var requestURL:URL?
    private var task:Task<Void,Never>?
    private var operation=UUID()
    private struct DownloadIntent {
        let video:String
        let audio:String
        let open:(TemporaryImport)->Void
    }
    private var pendingDownload:DownloadIntent?

    init(service:any URLImportServicing=URLImportService()) { self.service=service }
    var includesAudio:Bool { media?.videos.first(where:{ $0.id == video })?.hasAudio == true }
    var excludesAudio:Bool { audio == "none" }
    var showsStatus:Bool { busy && (formatsVisible || downloadRequested) }

    /// New presentation. Paste can start looking up before SwiftUI mounts the sheet.
    func begin(url:URL?=nil) {
        resetLookup()
        if let url { urlText=url.absoluteString; prefetch() }
    }

    func resetLookup() {
        guard !downloadRequested else { return }
        operation=UUID(); task?.cancel(); task=nil
        busy=false; cancelling=false; pendingDownload=nil
        media=nil; requestURL=nil; formatsVisible=false; video="best"; audio="best"; error=nil; status=""; progress=nil
    }

    func urlChanged() {
        // A programmatically prefilled URL can be observed after the lookup has started.
        guard requestURL != nil else { error=nil; return }
        if let url=try? URLMedia.parseURL(urlText), url == requestURL { return }
        resetLookup()
    }

    func useDefaultFormats() {
        guard !downloadRequested else { return }
        formatsVisible=false; video="best"; audio="best"
    }

    func selectVideo(_ id:String) {
        video=id
        if includesAudio && audio != "none" { audio="best" }
    }

    func prefetch() {
        urlChanged()
        guard !busy, media == nil else { return }
        start()
    }

    func showFormats() {
        guard !cancelling else { return }
        urlChanged()
        formatsVisible=true
        prefetch()
    }

    func download(open:@escaping(TemporaryImport)->Void) {
        guard !downloadRequested, !cancelling else { return }
        do { _=try URLMedia.parseURL(urlText) }
        catch { self.error=error.localizedDescription; return }
        urlChanged()
        pendingDownload=DownloadIntent(video:formatsVisible ? video : "best",audio:formatsVisible ? audio : "best",open:open)
        downloadRequested=true
        // If a paste already started a lookup, its task consumes this intent when it finishes.
        if !busy { start() }
    }

    private func start() {
        guard !busy else { return }
        let url:URL
        do { url=try URLMedia.parseURL(urlText) }
        catch { self.error=error.localizedDescription; downloadRequested=false; pendingDownload=nil; return }
        let cached=requestURL == url ? media : nil
        requestURL=url
        error=nil; busy=true; progress=nil; status="Preparing download…"
        let token=UUID(); operation=token
        task=Task { [self] in
            defer {
                if operation == token {
                    busy=false; task=nil; progress=nil; pendingDownload=nil; downloadRequested=false; cancelling=false
                }
            }
            do {
                let tools=try await service.prepare { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.operation == token, self.busy, !self.cancelling else { return }
                        self.status=message
                    }
                }
                try Task.checkCancellation()
                let info:URLMedia
                if let cached { info=cached }
                else {
                    status="Loading formats…"
                    info=try await service.inspect(url:url,tools:tools)
                    try Task.checkCancellation()
                    guard operation == token else { return }
                    media=info
                }
                guard let intent=pendingDownload else { status=""; return }
                let selector=try info.selector(video:intent.video,audio:intent.audio)
                status="Downloading…"
                let result=try await service.download(url:url,media:info,selector:selector,
                    excludeAudio:intent.audio == "none",tools:tools) { [weak self] update in
                        Task { @MainActor in
                            guard let self, self.operation == token, self.busy, !self.cancelling else { return }
                            self.status=update.label; self.progress=update.fraction
                        }
                    }
                try Task.checkCancellation()
                guard operation == token else { return }
                status=""; busy=false; downloadRequested=false; pendingDownload=nil
                intent.open(result)
            } catch is CancellationError {
                if operation == token { status="Cancelled" }
            } catch {
                if operation == token { self.error=error.localizedDescription; status="" }
            }
        }
    }

    func cancel() {
        guard busy else { return }
        status="Cancelling…"; cancelling=true; pendingDownload=nil; task?.cancel()
    }
    func endPresentation() {
        if !downloadRequested { resetLookup() }
    }
    func cancelAndWait() async { let current=task; cancel(); await current?.value }
}

/// Owns one downloaded source. Exports live outside this directory.
final class TemporaryImport:@unchecked Sendable {
    let directory:URL
    let file:URL
    static var root:URL { FileManager.default.temporaryDirectory.appendingPathComponent("Clipper/Imports",isDirectory:true) }
    init(directory:URL,file:URL) { self.directory=directory; self.file=file }
    func dispose() { try? FileManager.default.removeItem(at:directory) }
    deinit { dispose() }
}

struct ImportProgress:Sendable {
    let label:String
    let fraction:Double?
    static func parse(_ line:String) -> ImportProgress? {
        if line.hasPrefix("CLIPPER_PROGRESS:") {
            let text=String(line.dropFirst("CLIPPER_PROGRESS:".count))
            guard let data=text.data(using:.utf8), let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return nil }
            let downloaded=(json["downloaded_bytes"] as? NSNumber)?.doubleValue
            let total=(json["total_bytes"] as? NSNumber)?.doubleValue ?? (json["total_bytes_estimate"] as? NSNumber)?.doubleValue
            let fraction:Double?
            if let downloaded, let total, total > 0 { fraction=max(0,min(1,downloaded/total)) } else { fraction=nil }
            var label="Downloading"
            if let fraction { label += " \(Int(fraction*100))% of current stream" }
            if let speed=(json["speed"] as? NSNumber)?.doubleValue, speed.isFinite, speed > 0, speed < Double(Int64.max) {
                label += " · \(ByteCountFormatter.string(fromByteCount:Int64(speed),countStyle:.file))/s"
            }
            return ImportProgress(label:label,fraction:fraction)
        }
        if line.hasPrefix("CLIPPER_POST:") { return ImportProgress(label:"Preparing downloaded media…",fraction:nil) }
        return nil
    }
}

enum URLMediaDownload {
    static func arguments(tools:ImportTools) -> [String] {
        ["--ignore-config","--no-plugin-dirs","--no-update","--no-remote-components",
         "--no-js-runtimes","--js-runtimes","deno:\(tools.deno.path)",
         "--ffmpeg-location",tools.ffmpegDirectory.path,"--no-playlist","--playlist-items","1","--no-colors","--newline",
         "--socket-timeout","30","--retries","3","--fragment-retries","3"]
    }

    static func environment(workspace:URL) throws -> [String:String] {
        let root=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("Clipper/URLImport",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var result=ImportProcess.environment
        result["DENO_DIR"]=root.appendingPathComponent("Deno").path
        result["DENO_NO_UPDATE_CHECK"]="1"
        result["TMPDIR"]=workspace.path+"/"
        return result
    }

    static func inspect(url:URL,tools:ImportTools) async throws -> URLMedia {
        let workspace=FileManager.default.temporaryDirectory.appendingPathComponent("clipper-lookup-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:workspace) }
        let data=try await ImportProcess().run(executable:tools.ytDLP,
            arguments:arguments(tools:tools)+["--no-cache-dir","--dump-single-json","--skip-download","--",url.absoluteString],
            directory:workspace,environment:try environment(workspace:workspace))
        let media:URLMedia
        do { media=try URLMedia.decode(data) }
        catch let error as ImportFailure { throw error }
        catch { throw ImportFailure.message("Could not read video formats. Try downloading again.") }
        try media.validate()
        return media
    }

    static func download(url:URL,media:URLMedia,selector:String,excludeAudio:Bool=false,tools:ImportTools,
                         temporaryRoot:URL=TemporaryImport.root,
                         progress:@escaping @Sendable(ImportProgress)->Void) async throws -> TemporaryImport {
        let files=FileManager.default
        try files.createDirectory(at:temporaryRoot,withIntermediateDirectories:true)
        let workspace=temporaryRoot.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try files.createDirectory(at:workspace,withIntermediateDirectories:false)
        var completed=false
        defer { if !completed { try? files.removeItem(at:workspace) } }
        let args=arguments(tools:tools)+["--no-cache-dir","--no-simulate","--no-overwrites","--progress","--progress-delta","0.25","--format",selector,
            "--merge-output-format","mkv","--output",workspace.appendingPathComponent("source.%(ext)s").path,
            "--progress-template","download:CLIPPER_PROGRESS:%(progress)j",
            "--progress-template","postprocess:CLIPPER_POST:%(progress.status)s",
            "--print","after_move:CLIPPER_FILE:%(filepath)j","--",url.absoluteString]
        let output=try await ImportProcess().run(executable:tools.ytDLP,arguments:args,directory:workspace,
            environment:try environment(workspace:workspace),outputLimit:1024*1024,truncatingOutput:true) { line in
                if let update=ImportProgress.parse(line) { progress(update) }
            }
        try Task.checkCancellation()
        var file=try completedFile(output:output,workspace:workspace)
        if excludeAudio {
            progress(ImportProgress(label:"Removing audio…",fraction:nil))
            let silent=workspace.appendingPathComponent("silent.mkv")
            _=try await ImportProcess().run(executable:tools.ffmpegDirectory.appendingPathComponent("ffmpeg"),
                arguments:["-hide_banner","-loglevel","error","-nostdin","-n","-i",file.path,"-map","0:v:0","-c:v","copy","-an","-sn","-dn",silent.path])
            try files.removeItem(at:file); file=silent
        }
        progress(ImportProgress(label:"Checking downloaded media…",fraction:nil))
        let probe=try await ImportProcess().run(executable:tools.ffmpegDirectory.appendingPathComponent("ffprobe"),
            arguments:["-v","error","-show_entries","stream=codec_type","-of","json",file.path])
        let json=try JSONSerialization.jsonObject(with:probe) as? [String:Any]
        let streams=json?["streams"] as? [[String:Any]] ?? []
        guard streams.contains(where:{ $0["codec_type"] as? String == "video" }) else {
            throw ImportFailure.message("The download did not contain a playable video stream.")
        }
        try Task.checkCancellation()
        let published=try publish(file:URLMedia.filename(title:media.title),source:file,destination:workspace)
        completed=true
        return TemporaryImport(directory:workspace,file:published)
    }

    static func completedFile(output:Data,workspace:URL) throws -> URL {
        let paths=String(decoding:output,as:UTF8.self).components(separatedBy:"\n").filter { $0.hasPrefix("CLIPPER_FILE:") }
        guard paths.count == 1, let line=paths.first,
              let data=String(line.dropFirst("CLIPPER_FILE:".count)).data(using:.utf8),
              let path=try? JSONDecoder().decode(String.self,from:data) else {
            throw ImportFailure.message("The downloader did not report a completed file.")
        }
        let file=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath()
        let root=workspace.standardizedFileURL.resolvingSymlinksInPath()
        let attributes=try FileManager.default.attributesOfItem(atPath:file.path)
        guard file.deletingLastPathComponent() == root, attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw ImportFailure.message("The downloader returned an invalid output file.")
        }
        return file
    }

    static func publish(file name:String,source:URL,destination:URL) throws -> URL {
        let ext=source.pathExtension
        guard ext.range(of:"^[A-Za-z0-9]+$",options:.regularExpression) != nil else { throw ImportFailure.message("The download has an unknown file type.") }
        var suffix=1
        while true {
            let output=destination.appendingPathComponent("\(name)\(suffix == 1 ? "" : "-\(suffix)").\(ext)")
            do { try FileManager.default.moveItem(at:source,to:output); return output }
            catch CocoaError.fileWriteFileExists { suffix += 1 }
        }
    }
}
