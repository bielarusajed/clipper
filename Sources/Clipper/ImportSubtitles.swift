import Foundation

/// Subtitles fetched beside a URL import, then muxed into the source so the editor lists them as container tracks.
struct ImportedSubtitle:Equatable {
    let subtitle:URLSubtitle
    let file:URL
    var format:String { file.pathExtension.lowercased() }
}

enum ImportSubtitles {
    /// A separate, non-fatal yt-dlp run. Missing or rate-limited captions never fail the video download.
    static func fetch(url:URL,subtitles:[URLSubtitle],tools:ImportTools,workspace:URL) async -> [ImportedSubtitle] {
        guard !subtitles.isEmpty else { return [] }
        let directory=workspace.appendingPathComponent("subtitles",isDirectory:true)
        do { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) } catch { return [] }
        var args=URLMediaDownload.arguments(tools:tools)+["--no-cache-dir","--skip-download","--ignore-errors",
            "--sub-format","ass/srt/vtt/best","--sub-langs",subtitles.map(\.pattern).joined(separator:",")]
        if subtitles.contains(where:{ $0.kind == .authored }) { args.append("--write-subs") }
        if subtitles.contains(where:{ $0.kind != .authored }) { args.append("--write-auto-subs") }
        args += ["--output",directory.appendingPathComponent("s.%(ext)s").path,"--",url.absoluteString]
        _=try? await ImportProcess().run(executable:tools.ytDLP,arguments:args,directory:workspace,
            environment:try URLMediaDownload.environment(workspace:workspace))
        if Task.isCancelled { return [] }
        return collect(directory:directory,subtitles:subtitles)
    }

    /// yt-dlp names each file "s.<language>.<ext>". Keep the requested order and text formats only.
    static func collect(directory:URL,subtitles:[URLSubtitle]) -> [ImportedSubtitle] {
        let names=(try? FileManager.default.contentsOfDirectory(atPath:directory.path)) ?? []
        return subtitles.compactMap { subtitle in
            for format in ["ass","ssa","srt","vtt"] where names.contains("s.\(subtitle.language).\(format)") {
                let file=directory.appendingPathComponent("s.\(subtitle.language).\(format)")
                let size=(try? FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size > 0, size <= 32*1024*1024 else { return nil }
                return ImportedSubtitle(subtitle:subtitle,file:file)
            }
            return nil
        }
    }

    /// Container subtitles render in the file's own timestamps. Site captions count from the start of the
    /// original video, so move them by the downloaded file's first timestamp minus any section offset.
    /// Cues that end before zero are dropped: FFmpeg would otherwise shift every stream to fit them.
    static func mux(file:URL,subtitles:[ImportedSubtitle],shift:Double,existingSubtitleStreams:Int,
                    workspace:URL,ffmpeg:URL) async throws -> URL? {
        var inputs=[(ImportedSubtitle,URL)]()
        for (index,item) in subtitles.enumerated() {
            guard let data=try? Data(contentsOf:item.file), let text=try? SubtitleComposer.decode(data),
                  let shifted=SubtitleShift.shift(text,format:item.format,by:shift) else { continue }
            let output=workspace.appendingPathComponent("subtitle-\(index).\(item.format)")
            try shifted.write(to:output,atomically:true,encoding:.utf8)
            inputs.append((item,output))
        }
        guard !inputs.isEmpty else { return nil }
        let muxed=workspace.appendingPathComponent("subtitled.mkv")
        var args=["-hide_banner","-loglevel","error","-nostdin","-n","-copyts","-i",file.path]
        for (item,input) in inputs { args += ["-f",item.format == "vtt" ? "webvtt" : item.format == "srt" ? "srt" : "ass","-i",input.path] }
        args += ["-map","0"]
        for index in inputs.indices { args += ["-map","\(index+1):0"] }
        args += ["-c","copy","-dn"]
        for (offset,(item,_)) in inputs.enumerated() {
            let stream=existingSubtitleStreams+offset
            args += ["-metadata:s:s:\(stream)","language=\(item.subtitle.language)","-metadata:s:s:\(stream)","title=\(item.subtitle.label)"]
        }
        args.append(muxed.path)
        _=try await ImportProcess().run(executable:ffmpeg,arguments:args)
        return muxed
    }
}

/// Moves SRT, WebVTT and ASS cue times. Returns nil when no cue remains.
enum SubtitleShift {
    static func shift(_ text:String,format:String,by seconds:Double) -> String? {
        let delta=Int64((seconds*1000).rounded())
        let normalized=text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        let result=["ass","ssa"].contains(format) ? shiftASS(normalized,by:delta) : shiftCues(normalized,vtt:format == "vtt",by:delta)
        return result.cues > 0 ? result.text : nil
    }

    private static let clock=try! NSRegularExpression(pattern:#"(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})"#)
    static func milliseconds(_ value:String) -> Int64? {
        let range=NSRange(value.startIndex...,in:value)
        guard let match=clock.firstMatch(in:value,range:range), match.range == range else { return nil }
        func part(_ i:Int)->Int64 { Range(match.range(at:i),in:value).flatMap { Int64(value[$0]) } ?? 0 }
        let fraction=Range(match.range(at:4),in:value).map { String(value[$0]) } ?? "0"
        let ms=Int64(fraction.padding(toLength:3,withPad:"0",startingAt:0)) ?? 0
        return ((part(1)*60+part(2))*60+part(3))*1000+ms
    }
    private static func format(_ ms:Int64,separator:String) -> String {
        let v=max(0,ms)
        return String(format:"%02lld:%02lld:%02lld%@%03lld",v/3_600_000,v/60_000%60,v/1000%60,separator,v%1000)
    }

    private static func shiftCues(_ text:String,vtt:Bool,by delta:Int64) -> (text:String,cues:Int) {
        let timing=try! NSRegularExpression(pattern:#"^\s*(\S+)\s+-->\s+(\S+)(.*)$"#)
        let inline=try! NSRegularExpression(pattern:#"<((?:\d+:)?\d{1,2}:\d{2}\.\d{1,3})>"#)
        var blocks=[String](), cues=0
        for block in text.components(separatedBy:"\n\n") {
            var lines=block.components(separatedBy:"\n")
            guard let index=lines.firstIndex(where:{ $0.contains("-->") }) else { blocks.append(block); continue }
            let line=lines[index], range=NSRange(line.startIndex...,in:line)
            guard let match=timing.firstMatch(in:line,range:range),
                  let start=Range(match.range(at:1),in:line).flatMap({ milliseconds(String(line[$0])) }),
                  let end=Range(match.range(at:2),in:line).flatMap({ milliseconds(String(line[$0])) }) else { continue }
            guard end+delta > 0 else { continue }
            let settings=Range(match.range(at:3),in:line).map { String(line[$0]) } ?? ""
            let separator=vtt ? "." : ","
            lines[index]="\(format(start+delta,separator:separator)) --> \(format(end+delta,separator:separator))\(settings)"
            if vtt {
                for i in lines.indices where i > index {
                    let text=lines[i] as NSString
                    for tag in inline.matches(in:lines[i],range:NSRange(location:0,length:text.length)).reversed() {
                        let value=milliseconds(text.substring(with:tag.range(at:1))) ?? 0
                        lines[i]=(lines[i] as NSString).replacingCharacters(in:tag.range,with:"<\(format(value+delta,separator:"."))>")
                    }
                }
            }
            blocks.append(lines.joined(separator:"\n")); cues += 1
        }
        return (blocks.joined(separator:"\n\n"),cues)
    }

    private static func shiftASS(_ text:String,by delta:Int64) -> (text:String,cues:Int) {
        func time(_ ms:Int64)->String {
            let v=max(0,ms)
            return String(format:"%lld:%02lld:%02lld.%02lld",v/3_600_000,v/60_000%60,v/1000%60,v%1000/10)
        }
        var output=[String](), fields=[String](), inEvents=false, cues=0
        for line in text.components(separatedBy:"\n") {
            let trimmed=line.trimmingCharacters(in:.whitespaces)
            if trimmed.hasPrefix("[") { inEvents=trimmed.lowercased() == "[events]" }
            if inEvents, trimmed.lowercased().hasPrefix("format:") {
                fields=trimmed.dropFirst(7).split(separator:",").map { $0.trimmingCharacters(in:.whitespaces).lowercased() }
            }
            guard inEvents, trimmed.lowercased().hasPrefix("dialogue:"),
                  let s=fields.firstIndex(of:"start"), let e=fields.firstIndex(of:"end") else { output.append(line); continue }
            let head=trimmed.prefix(9)
            var values=trimmed.dropFirst(9).split(separator:",",maxSplits:max(1,fields.count-1),omittingEmptySubsequences:false).map(String.init)
            guard s < values.count, e < values.count,
                  let start=milliseconds(values[s].trimmingCharacters(in:.whitespaces)),
                  let end=milliseconds(values[e].trimmingCharacters(in:.whitespaces)) else { output.append(line); continue }
            guard end+delta > 0 else { continue }
            values[s]=time(start+delta); values[e]=time(end+delta)
            output.append(head+values.joined(separator:",")); cues += 1
        }
        return (output.joined(separator:"\n"),cues)
    }
}
