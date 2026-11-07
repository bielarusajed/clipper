import Foundation

struct URLMedia: Decodable {
    let id:String
    let title:String
    let duration:Double?
    let formats:[URLMediaFormat]
    let liveStatus:String?
    let isLive:Bool?
    let type:String?
    let startTime:Double?
    var timestampHint:Double? {
        guard let time=startTime, time.isFinite, time > 0, time < ImportRange.maximumTime,
              duration == nil || time < duration! else { return nil }
        return time
    }

    enum CodingKeys:String,CodingKey {
        case id,title,duration,formats
        case startTime="start_time"
        case liveStatus="live_status", isLive="is_live", type="_type"
    }

    var videos:[URLMediaFormat] { formats.reversed().filter { $0.selectable && $0.hasVideo } }
    var audios:[URLMediaFormat] { formats.reversed().filter { $0.selectable && !$0.hasVideo && $0.hasAudio } }

    static func decode(_ data:Data) throws -> URLMedia {
        if let json=try JSONSerialization.jsonObject(with:data) as? [String:Any],
           let type=json["_type"] as? String, type != "video" {
            throw ImportFailure.message("Enter a URL for one video, rather than a playlist or channel.")
        }
        return try JSONDecoder().decode(URLMedia.self,from:data)
    }

    func validate() throws {
        guard type == nil || type == "video" else { throw ImportFailure.message("Enter a URL for one video, rather than a playlist or channel.") }
        guard isLive != true, !["is_live","is_upcoming"].contains(liveStatus ?? "") else {
            throw ImportFailure.message("Live and scheduled streams cannot be imported. Try again when the recording is available.")
        }
        guard !videos.isEmpty else { throw ImportFailure.message("No downloadable video formats were found. The URL may be unsupported, private, or DRM protected.") }
    }

    func selector(video:String,audio:String) throws -> String {
        let chosen=videos.first { $0.id == video }
        guard video == "best" || chosen != nil else { throw ImportFailure.message("Choose an available video format.") }
        if chosen?.hasAudio == true { return video }
        let v=video == "best" ? "bv" : video
        if audio == "none" { return video == "best" ? "bv/b" : v }
        if audios.isEmpty { return video == "best" ? "bv/b" : v }
        guard audio == "best" || audios.contains(where:{ $0.id == audio }) else { throw ImportFailure.message("Choose an available audio format.") }
        let a=audio == "best" ? "ba" : audio
        return video == "best" && audio == "best" ? "\(v)+\(a)/b" : "\(v)+\(a)"
    }

    static func parseURL(_ text:String) throws -> URL {
        guard let url=URL(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),
              ["http","https"].contains(url.scheme?.lowercased() ?? ""),
              let host=url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw ImportFailure.message("Enter a complete http:// or https:// video URL.")
        }
        return url
    }

    static func filename(title:String) -> String {
        let invalid=CharacterSet.controlCharacters.union(CharacterSet(charactersIn:"/:\\"))
        let clean=title.components(separatedBy:invalid).joined(separator:" ").trimmingCharacters(in:.whitespacesAndNewlines)
        var bounded=""
        for character in clean.prefix(120) {
            let next=String(character)
            if bounded.utf8.count+next.utf8.count > 180 { break }
            bounded += next
        }
        let prefix=bounded.trimmingCharacters(in:CharacterSet(charactersIn:". "))
        return prefix.isEmpty ? "Imported video" : prefix
    }
}

struct URLMediaFormat: Decodable, Identifiable {
    let id:String
    let ext:String?
    let vcodec:String?
    let acodec:String?
    let width:Int?
    let height:Int?
    let fps:Double?
    let abr:Double?
    let tbr:Double?
    let protocolName:String?
    let language:String?
    let note:String?
    let dynamicRange:String?
    let filesize:Double?
    let filesizeApprox:Double?
    let hasDRM:Bool?
    enum CodingKeys:String,CodingKey {
        case id="format_id", ext,vcodec,acodec,width,height,fps,abr,tbr,language,filesize
        case protocolName="protocol"
        case note="format_note", dynamicRange="dynamic_range", filesizeApprox="filesize_approx", hasDRM="has_drm"
    }
    init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        id=try values.decode(String.self,forKey:.id)
        ext=try? values.decode(String.self,forKey:.ext)
        vcodec=try? values.decode(String.self,forKey:.vcodec)
        acodec=try? values.decode(String.self,forKey:.acodec)
        width=try? values.decode(Int.self,forKey:.width)
        height=try? values.decode(Int.self,forKey:.height)
        fps=try? values.decode(Double.self,forKey:.fps)
        abr=try? values.decode(Double.self,forKey:.abr)
        tbr=try? values.decode(Double.self,forKey:.tbr)
        protocolName=try? values.decode(String.self,forKey:.protocolName)
        language=try? values.decode(String.self,forKey:.language)
        note=try? values.decode(String.self,forKey:.note)
        dynamicRange=try? values.decode(String.self,forKey:.dynamicRange)
        filesize=try? values.decode(Double.self,forKey:.filesize)
        filesizeApprox=try? values.decode(Double.self,forKey:.filesizeApprox)
        // yt-dlp also reports "maybe". Only a literal true rules a format out.
        hasDRM=try? values.decode(Bool.self,forKey:.hasDRM)
    }
    // Extractors use "none" for an absent stream; a missing codec can mean unknown.
    var hasVideo:Bool { vcodec != "none" && (vcodec != nil || acodec == nil || width != nil || height != nil) }
    var hasAudio:Bool { acodec != "none" }
    var selectable:Bool {
        hasDRM != true && id.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil
    }
    var resolutionText:String {
        if let width, let height { return "\(width)×\(height)" }
        if let height { return "\(height)p" }
        return hasVideo ? "Unknown" : "Audio"
    }
    var fpsText:String { fps.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "" }
    var sizeText:String {
        guard let bytes=filesize ?? filesizeApprox, bytes.isFinite, bytes > 0, bytes < Double(Int64.max) else { return "" }
        return (filesize == nil ? "~" : "")+ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.file)
    }
    var videoCodecText:String { hasVideo ? vcodec ?? "Unknown" : "" }
    var audioCodecText:String { hasAudio ? acodec ?? "Unknown" : "" }
    var detailsText:String {
        var parts=[language,note,dynamicRange == "SDR" ? nil : dynamicRange,protocolName].compactMap { $0 }
        if let rate=hasVideo ? tbr : abr, rate.isFinite, rate > 0, rate < 1_000_000 { parts.append("\(Int(rate))k") }
        return parts.joined(separator:" · ")
    }
    var label:String {
        var parts=[String]()
        if hasVideo {
            parts.append(height.map { "\($0)p" } ?? "Video")
            if let fps, fps > 0 { parts.append("\(fps.formatted(.number.precision(.fractionLength(0...2)))) fps") }
            if let dynamicRange, dynamicRange != "SDR" { parts.append(dynamicRange) }
            if let vcodec { parts.append(vcodec) }
            if hasAudio { parts.append("includes audio") }
        } else {
            if let language { parts.append(language) }
            if let note { parts.append(note) }
            if let acodec { parts.append(acodec) }
            if let abr, abr > 0 { parts.append("\(Int(abr)) kb/s") }
        }
        if let ext { parts.append(ext.uppercased()) }
        if let bytes=filesize ?? filesizeApprox, bytes.isFinite, bytes > 0, bytes < Double(Int64.max) {
            parts.append((filesize == nil ? "~" : "")+ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.file))
        }
        parts.append("[\(id)]")
        return parts.joined(separator:" · ")
    }
}
