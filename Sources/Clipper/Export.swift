import Foundation

struct ExportRequest {
    let source: URL
    let details: MediaDetails
    let edit: EditSettings
    let start: Double
    let end: Double
    let destination: URL

    func arguments() throws -> [String] {
        guard start >= 0, end > start, end <= details.duration+0.1 else { throw ExportFailure.message("Choose a non-empty clip inside the video.") }
        let g=edit.geometry(for:details)
        let keepHDR=details.hdr && !edit.convertToSDR
        if keepHDR && edit.codec != .hevc { throw ExportFailure.message("HDR needs H.265. Choose H.265 or turn on Convert to SDR.") }
        if edit.codec == .h264 && max(g.outWidth,g.outHeight) > 4096 { throw ExportFailure.message("This size exceeds the H.264 encoder on this Mac. Choose H.265 or a smaller resolution.") }
        func number(_ v: Double) -> String { String(format:"%.9f",locale:Locale(identifier:"en_US_POSIX"),v) }
        let absoluteStart=start+details.origin, absoluteEnd=end+details.origin
        var args=["-hide_banner","-nostdin","-loglevel","error","-n","-copyts"]
        // Seek by absolute source time and keep preroll; trim after decoding.
        if start > 12 { args += ["-seek_timestamp","1","-ss",number(absoluteStart-10),"-noaccurate_seek"] }
        args += ["-i",source.path,"-map","0:v:0"]
        var filters=["trim=start=\(number(absoluteStart)):end=\(number(absoluteEnd))","setpts=PTS-(\(number(absoluteStart)))/TB"]
        if details.hdr && edit.convertToSDR {
            filters += ["zscale=t=linear:npl=100","format=gbrpf32le","tonemap=tonemap=hable:desat=0","zscale=p=bt709:t=bt709:m=bt709:r=tv","format=yuv420p"]
        }
        // FFmpeg autorotates before the filter graph. Square pixels before crop.
        if abs(details.pixelAspect-1) > 0.001 {
            let size=details.displaySize
            filters += ["scale=\(Int(size.width/2)*2):\(Int(size.height/2)*2)","setsar=1"]
        }
        filters += ["crop=\(g.width):\(g.height):\(g.x):\(g.y)","scale=\(g.outWidth):\(g.outHeight):flags=lanczos","setsar=1"]
        args += ["-vf",filters.joined(separator:","),"-c:v",edit.codec.encoder,"-allow_sw","0","-realtime","0","-q:v",String(Int(edit.quality)),"-pix_fmt",keepHDR ? "p010le" : "nv12","-fps_mode","passthrough"]
        if edit.codec == .hevc { args += ["-tag:v","hvc1","-profile:v",keepHDR ? "main10" : "main"] }
        if details.hdr && edit.convertToSDR { args += ["-color_primaries","bt709","-color_trc","bt709","-colorspace","bt709"] }
        if !edit.muted && details.audioStreams.indices.contains(edit.audioTrack) {
            args += ["-map","0:\(details.audioStreams[edit.audioTrack])","-af","atrim=start=\(number(absoluteStart)):end=\(number(absoluteEnd)),asetpts=PTS-(\(number(absoluteStart)))/TB","-c:a","aac_at","-b:a","192k","-ac","2"]
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
                    if let n=Double(line.dropFirst(12)) { progress(min(0.99,max(0,n/1000000/(request.end-request.start)))) }
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
