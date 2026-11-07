import Foundation
import CMedia

/// A request in the original video's clock. Decoder and export times remain local.
struct ImportRange:Equatable,Sendable {
    let start:Double
    let end:Double
    static let padding=5.0
    static let maximumTime=31_536_000.0

    init(start:Double,end:Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= Self.maximumTime else {
            throw ImportFailure.message("Enter a start before the end, between 0 and 365 days.")
        }
        self.start=start; self.end=end
    }
    init(startText:String,endText:String) throws {
        guard let start=TimeText.parse(startText), let end=TimeText.parse(endText) else {
            throw ImportFailure.message("Enter both range times as seconds or hh:mm:ss.sss.")
        }
        try self.init(start:start,end:end)
    }
    func validate(duration:Double?) throws {
        if let duration, duration.isFinite, duration > 0 {
            guard start < duration, end <= duration+0.001 else {
                throw ImportFailure.message("The range must fit inside the video (\(TimeText.format(duration))).")
            }
        }
    }
    var paddedStart:Double { max(0,start-Self.padding) }
    func paddedEnd(duration:Double?)->Double {
        min(end+Self.padding,duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? end+Self.padding)
    }
    func downloaderArguments(duration:Double?) throws -> [String] {
        try validate(duration:duration)
        return ["--download-sections","*\(Self.number(paddedStart))-\(Self.number(paddedEnd(duration:duration)))",
                "--downloader-args","ffmpeg_i1:-copyts -start_at_zero"]
    }
    static func number(_ value:Double)->String { String(format:"%.6f",locale:Locale(identifier:"en_US_POSIX"),value) }
}

/// Measured before and after a timestamp-only local copy, never inferred from the requested start.
struct ImportTimeline:Equatable,Sendable {
    let offset:Double
    let localOrigin:Double
    func original(_ local:Double)->Double { local+offset }
    func local(_ original:Double)->Double { original-offset }
}

struct ImportProbe:Decodable {
    struct Format:Decodable { let start_time:String?; let duration:String? }
    struct Stream:Decodable { let codec_type:String? }
    let format:Format?
    let streams:[Stream]?
    var start:Double? { format?.start_time.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
    var duration:Double? { format?.duration.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }

    static func read(file:URL,tools:ImportTools) async throws -> Self {
        let data=try await ImportProcess().run(executable:tools.ffmpegDirectory.appendingPathComponent("ffprobe"),
            arguments:["-v","error","-show_entries","format=start_time,duration:stream=codec_type","-of","json",file.path])
        let probe=try JSONDecoder().decode(Self.self,from:data)
        guard probe.streams?.contains(where:{ $0.codec_type == "video" }) == true else {
            throw ImportFailure.message("The download did not contain a playable video stream.")
        }
        return probe
    }

    /// Decoding the first and final frame checks actual video coverage, not audio/container length.
    static func verify(file:URL,range:ImportRange,offset:Double,expectedOrigin:Double) async throws {
        try await Task.detached {
            try Task.checkCancellation()
            var error=[CChar](repeating:0,count:512)
            guard let media=clip_open(file.path,-1,&error,512) else {
                throw ImportFailure.message("Could not decode the downloaded section.")
            }
            defer { clip_close(media) }
            let info=clip_info(media)
            guard abs(info.origin-expectedOrigin) < 0.002 else {
                throw ImportFailure.message("Could not verify the section's original timestamps. Try importing the full video.")
            }
            let first=clip_frame(media,0)
            defer { first.sample?.release() }
            let last=clip_frame(media,max(0,info.duration-0.000001))
            defer { last.sample?.release() }
            guard first.kind == 1, last.kind == 1,
                  first.time+offset <= range.start+0.002,
                  last.time+last.duration+offset >= range.end-0.002 else {
                throw ImportFailure.message("The downloaded section does not cover the requested range. Try a wider range or import the full video.")
            }
        }.value
        try Task.checkCancellation()
    }
}
