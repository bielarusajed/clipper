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
                "--downloader-args","ffmpeg_i:-copyts -start_at_zero -protocol_whitelist http,https,tcp,tls,crypto -rw_timeout 30000000",
                "--downloader-args","ffmpeg_o:-sn -dn -f matroska","--fixup","never"]
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
    static func verify(file:URL,range:ImportRange,offset:Double,expectedOrigin:Double,sourceDuration:Double?=nil) async throws {
        let request=ImportVerificationRequest()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
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
                let first=clip_frame_cancellable(media,0,request.pointer,0)
                defer { first.sample?.release() }
                let last=clip_frame_cancellable(media,max(0,info.duration-0.000001),request.pointer,0)
                defer { last.sample?.release() }
                if first.kind == -3 || last.kind == -3 { throw CancellationError() }
                // At the real source edges, audio may lead video and site durations may round up.
                // Bound metadata rounding to one second; interior cuts still require full coverage.
                let sourceStart=range.paddedStart == 0 && abs(offset-expectedOrigin) <= 0.1
                let sourceEnd=sourceDuration.map { $0.isFinite && $0 > 0 && range.paddedEnd(duration:$0) == $0 } ?? false
                let firstCovered=first.time+offset <= range.start+0.002 || (sourceStart && first.time+offset < range.end)
                let lastCovered=last.time+last.duration+offset >= range.end-(sourceEnd ? 1 : 0.002)
                guard first.kind == 1, last.kind == 1, firstCovered, lastCovered else {
                    throw ImportFailure.message("The downloaded section does not cover the requested range. Try a wider range or import the full video.")
                }
            }.value
        } onCancel: { request.cancel() }
        try Task.checkCancellation()
    }
}

private final class ImportVerificationRequest:@unchecked Sendable {
    let pointer=clip_request_create()!
    func cancel() { clip_request_set(pointer,1) }
    deinit { clip_request_free(pointer) }
}
