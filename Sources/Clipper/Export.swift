import Foundation

enum ExportDestination {
    static func validate(source:URL,destination:URL,managedDirectories:[URL]=[TemporaryImport.root]) throws {
        if isInManagedDirectory(destination,managedDirectories:managedDirectories) {
            throw ExportFailure.message("Choose a folder outside Clipper's temporary import area so your exported clip is kept.")
        }
        let input=source.standardizedFileURL.resolvingSymlinksInPath()
        let output=destination.standardizedFileURL.resolvingSymlinksInPath()
        var same=input == output
        if let a=try? FileManager.default.attributesOfItem(atPath:input.path),
           let b=try? FileManager.default.attributesOfItem(atPath:output.path),
           let aDevice=a[.systemNumber] as? NSNumber, let bDevice=b[.systemNumber] as? NSNumber,
           let aFile=a[.systemFileNumber] as? NSNumber, let bFile=b[.systemFileNumber] as? NSNumber {
            same = same || (aDevice == bDevice && aFile == bFile)
        }
        if same { throw ExportFailure.message("Choose a different filename from the source video.") }
    }

    /// The encoder writes beside the destination. Publish only a completed file,
    /// using replacement only when the save panel confirmed an existing output.
    static func publish(_ temporary:URL,to destination:URL,source:URL,replacingExisting:Bool,managedDirectories:[URL]=[TemporaryImport.root]) throws {
        try validate(source:source,destination:destination,managedDirectories:managedDirectories)
        let files=FileManager.default
        if replacingExisting && files.fileExists(atPath:destination.path) {
            _=try files.replaceItemAt(destination,withItemAt:temporary,options:.usingNewMetadataOnly)
        } else {
            try files.moveItem(at:temporary,to:destination)
        }
    }

    /// Compare existing directory identities, including through symlinks and
    /// case-insensitive spellings. The output file need not exist yet.
    static func isInManagedDirectory(_ destination:URL,managedDirectories:[URL]=[TemporaryImport.root]) -> Bool {
        func identity(_ url:URL) -> String? {
            guard let attributes=try? FileManager.default.attributesOfItem(atPath:url.path),
                  let device=attributes[.systemNumber] as? NSNumber,
                  let inode=attributes[.systemFileNumber] as? NSNumber else { return nil }
            return "\(device):\(inode)"
        }
        let roots=Set(managedDirectories.compactMap { identity($0.resolvingSymlinksInPath()) })
        var path=destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        while true {
            // A missing child may prevent Foundation resolving its symlinked
            // parent on the first pass. Resolve again as we reach each ancestor,
            // then walk that directory's real parents rather than the alias's.
            path=URL(fileURLWithPath:path).resolvingSymlinksInPath().path
            if let id=identity(URL(fileURLWithPath:path)), roots.contains(id) { return true }
            let parent=(path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == path { return false }
            path=parent
        }
    }
}

struct ExportRequest {
    let source: URL
    let details: MediaDetails
    let edit: EditSettings
    let start: Double
    let end: Double
    let destination: URL

    var subtitles: RenderSubtitles? = nil
    var outputDuration:Double { edit.speed.outputTime(end-start) }

    func arguments() throws -> [String] {
        guard start >= 0, end > start, end <= details.duration+0.1 else { throw ExportFailure.message("Choose a non-empty clip inside the video.") }
        let g=edit.geometry(for:details)
        if subtitles != nil && details.hdr && !edit.convertToSDR { throw ExportFailure.message("Burned-in subtitles need Convert to SDR for HDR videos.") }
        let keepHDR=details.hdr && !edit.convertToSDR
        if keepHDR && edit.codec != .hevc { throw ExportFailure.message("HDR needs H.265. Choose H.265 or turn on Convert to SDR.") }
        if edit.codec == .h264 && max(g.outWidth,g.outHeight) > 4096 { throw ExportFailure.message("This size exceeds the H.264 encoder on this Mac. Choose H.265 or a smaller resolution.") }
        func number(_ v: Double) -> String { String(format:"%.9f",locale:Locale(identifier:"en_US_POSIX"),v) }
        let absoluteStart=start+details.origin, absoluteEnd=end+details.origin
        var args=["-hide_banner","-nostdin","-loglevel","error","-n","-copyts"]
        // Seek by absolute source time and keep preroll; trim after decoding.
        if start > 12 { args += ["-seek_timestamp","1","-ss",number(absoluteStart-10),"-noaccurate_seek"] }
        args += ["-i",source.path,"-map","0:v:0"]
        var filters=["trim=start=\(number(absoluteStart)):end=\(number(absoluteEnd))"]
        let subtitleZero=subtitles?.zero ?? absoluteStart
        filters += ["setpts=PTS-(\(number(subtitleZero)))/TB"]
        if details.hdr && edit.convertToSDR {
            filters += ["zscale=t=linear:npl=100","format=gbrpf32le","tonemap=tonemap=hable:desat=0","zscale=p=bt709:t=bt709:m=bt709:r=tv","format=yuv420p"]
        }
        // Match the source decoder's fallback for untagged HD before blending RGB text.
        if subtitles != nil && !details.hdr && details.colorSpace == 2 && details.width >= 1280 {
            filters += ["setparams=colorspace=bt709"]
        }
        // FFmpeg autorotates before the filter graph. Square pixels before crop.
        if abs(details.pixelAspect-1) > 0.001 {
            let size=details.displaySize
            filters += ["scale=\(Int(size.width/2)*2):\(Int(size.height/2)*2)","setsar=1"]
        }
        if let subtitles, subtitles.preserve { filters += [subtitles.filter] }
        filters += ["crop=\(g.width):\(g.height):\(g.x):\(g.y)","scale=\(g.outWidth):\(g.outHeight):flags=lanczos","setsar=1"]
        if let subtitles {
            if !subtitles.preserve { filters += [subtitles.filter] }
            filters += ["setpts=PTS-(\(number(absoluteStart-subtitleZero)))/TB"]
        }
        // Burn cues on the source clock before changing the clip's timing.
        if edit.speed != .normal {
            filters += ["settb=AVTB","setpts=PTS/\(number(edit.speed.rawValue))"]
        }
        args += ["-vf",filters.joined(separator:","),"-c:v",edit.codec.encoder,"-allow_sw","0","-realtime","0","-q:v",String(Int(edit.quality)),"-pix_fmt",keepHDR ? "p010le" : "nv12","-fps_mode","passthrough"]
        if edit.speed != .normal {
            // Keep VFR timestamps precise. Scale packet durations too so the last
            // frame ends at the new rate without resampling or duplicating frames.
            // VideoToolbox may leave packet duration unset; use the source's
            // nominal frame duration in that case, as normal-speed export does.
            args += ["-enc_time_base:v","filter","-bsf:v","setts=duration='if(DURATION,DURATION,1/(\(number(details.fps))*TB))/\(number(edit.speed.rawValue))'"]
        }
        if edit.codec == .hevc { args += ["-tag:v","hvc1","-profile:v",keepHDR ? "main10" : "main"] }
        if details.hdr && edit.convertToSDR { args += ["-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709"] }
        if subtitles != nil && !details.hdr && details.colorSpace == 2 && details.width >= 1280 { args += ["-colorspace","bt709"] }
        if !edit.muted && details.audioStreams.indices.contains(edit.audioTrack) {
            var audioFilters=["atrim=start=\(number(absoluteStart)):end=\(number(absoluteEnd))","asetpts=PTS-(\(number(absoluteStart)))/TB"]
            audioFilters += edit.speed.audioTempos.map { "atempo=\(number($0))" }
            if edit.speed != .normal {
                // atempo retains the first PTS; scale a delayed track's offset too.
                audioFilters += ["asetpts=PTS-STARTPTS+STARTPTS/\(number(edit.speed.rawValue))"]
            }
            args += ["-map","0:\(details.audioStreams[edit.audioTrack])","-af",audioFilters.joined(separator:","),"-c:a","aac_at","-b:a","192k","-ac","2"]
        } else { args += ["-an"] }
        args += ["-sn","-dn","-map_metadata","-1","-movflags","+faststart","-progress","pipe:1","-nostats",destination.path]
        return args
    }
}
enum ExportFailure: LocalizedError {
    case message(String), cancelled
    var errorDescription: String? { switch self { case .message(let s): return s; case .cancelled: return "Export cancelled." } }
}
final class EncoderProcess: @unchecked Sendable {
    private let process=Process()
    private let lock=NSLock()
    private var cancelled=false
    func cancel() {
        lock.lock(); cancelled=true; let active=process.isRunning; lock.unlock()
        if active { process.terminate() }
    }
    func run(_ request: ExportRequest, progress: @escaping @Sendable (Double)->Void) async throws {
        let arguments=try request.arguments()
        let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        let local=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/media/bin/ffmpeg")
        let executable=FileManager.default.isExecutableFile(atPath:helper.path) ? helper : local
        guard FileManager.default.isExecutableFile(atPath:executable.path) else { throw ExportFailure.message("The bundled media engine is missing. Rebuild Clipper with scripts/build-app.sh.") }
        try await Task.detached(priority:.userInitiated) { [self] in
            let output=Pipe(), errors=Pipe()
            process.executableURL=executable; process.arguments=arguments
            process.standardOutput=output; process.standardError=errors
            let text=LockedText()
            output.fileHandleForReading.readabilityHandler = { h in
                let data=h.availableData
                guard !data.isEmpty else { return }
                let lines=text.appendProgress(String(decoding:data,as:UTF8.self))
                for line in lines where line.hasPrefix("out_time_us=") {
                    if let n=Double(line.dropFirst(12)) { progress(min(0.99,max(0,n/1000000/request.outputDuration))) }
                }
            }
            errors.fileHandleForReading.readabilityHandler = { h in text.appendError(h.availableData) }
            try lock.withLock {
                if cancelled { throw ExportFailure.cancelled }
                do { try process.run() }
                catch { throw ExportFailure.message("Could not start the media engine: \(error.localizedDescription)") }
            }
            process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler=nil
            errors.fileHandleForReading.readabilityHandler=nil
            text.appendError(errors.fileHandleForReading.readDataToEndOfFile())
            let wasCancelled=lock.withLock { cancelled }
            if wasCancelled { throw ExportFailure.cancelled }
            guard process.terminationStatus == 0 else {
                let detail=text.errorString.trimmingCharacters(in:.whitespacesAndNewlines)
                throw ExportFailure.message(detail.isEmpty ? "The hardware encoder could not finish. Try H.265 or a smaller resolution." : detail)
            }
            progress(1)
        }.value
    }
}
private final class LockedText: @unchecked Sendable {
    let lock=NSLock()
    var pending=""
    var errors=Data()
    func appendProgress(_ s: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending += s
        let lines=pending.components(separatedBy:"\n")
        pending=lines.last ?? ""
        return Array(lines.dropLast())
    }
    func appendError(_ d: Data) { lock.lock(); defer { lock.unlock() }; errors.append(d); if errors.count > 16000 { errors=errors.suffix(16000) } }
    var errorString: String { lock.lock(); defer { lock.unlock() }; return String(decoding:errors,as:UTF8.self) }
}
