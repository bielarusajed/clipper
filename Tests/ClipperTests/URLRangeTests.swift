import XCTest
import CMedia
import CoreImage
import AVFoundation
@testable import Clipper

final class URLRangeTests:XCTestCase {
    private let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
    private var engine:URL { root.appendingPathComponent(".build/media/bin/ffmpeg") }

    func testRangeValidationPaddingAndArguments() throws {
        let range=try ImportRange(startText:"08:00",endText:"00:08:30.25")
        XCTAssertEqual(range.start,480); XCTAssertEqual(range.end,510.25)
        XCTAssertEqual(range.paddedStart,475)
        XCTAssertEqual(range.paddedEnd(duration:512),512)
        XCTAssertEqual(try range.downloaderArguments(duration:nil),[
            "--download-sections","*475.000000-515.250000","--downloader-args","ffmpeg_i1:-copyts -start_at_zero"])
        XCTAssertEqual(try ImportRange(start:0,end:3).paddedStart,0)
        XCTAssertNoThrow(try range.validate(duration:nil))
        XCTAssertThrowsError(try range.validate(duration:500))
        for (start,end) in [("", "3"),("-1","3"),("3","3"),("4","3"),("nan","5"),("1","inf"),("1",""),("1","1e300")] {
            XCTAssertThrowsError(try ImportRange(startText:start,endText:end))
        }
        XCTAssertThrowsError(try ImportRange(start:0,end:.infinity))
    }

    func testMappingRoundTripsAndTimestampHintIsOnlyASuggestion() throws {
        let mapping=ImportTimeline(offset:477.123,localOrigin:0.103)
        XCTAssertEqual(mapping.original(16.377),493.5,accuracy:0.000001)
        XCTAssertEqual(mapping.local(493.5),16.377,accuracy:0.000001)
        let media=try info(extra:"\"start_time\":493.5,")
        XCTAssertEqual(media.timestampHint,493.5)
        XCTAssertNil(try info(extra:"\"start_time\":-3,").timestampHint)
    }

    private func info(extra:String="") throws -> URLMedia {
        try URLMedia.decode(Data("{\"id\":\"test\",\"title\":\"Range test\",\(extra)\"formats\":[{\"format_id\":\"18\",\"vcodec\":\"h264\",\"acodec\":\"aac\"}]}".utf8))
    }
    private func directory() throws -> URL {
        let dir=root.appendingPathComponent(".build/range-tests/\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        return dir
    }
    private func stub(_ directory:URL,script:String) throws -> ImportTools {
        let executable=directory.appendingPathComponent("downloader")
        try Data(("#!/bin/sh\n"+script).utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        return ImportTools(ytDLP:executable,deno:URL(fileURLWithPath:"/usr/bin/true"),ffmpegDirectory:engine.deletingLastPathComponent(),version:"test",notice:nil)
    }
    private func open(_ file:URL) throws -> OpaquePointer {
        var error=[CChar](repeating:0,count:512)
        return try XCTUnwrap(clip_open(file.path,-1,&error,512),String(cString:error))
    }
    private func details(_ info:ClipInfo)->MediaDetails {
        MediaDetails(duration:info.duration,origin:info.origin,width:Int(info.width),height:Int(info.height),rotation:0,pixelAspect:info.pixelAspect,fps:info.fps,hdr:false,codec:"h264",audioLabels:[],audioStreams:[])
    }

    @MainActor private func packets(_ file:URL) async throws -> [(Double,String)] {
        let data=try await ImportProcess().run(executable:engine.deletingLastPathComponent().appendingPathComponent("ffprobe"),
            arguments:["-v","error","-select_streams","v:0","-show_packets","-show_data_hash","sha256","-show_entries","packet=pts_time,data_hash","-of","json",file.path])
        let json=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        return (json["packets"] as! [[String:Any]]).compactMap {
            guard let time=$0["pts_time"] as? String, let value=Double(time), let hash=$0["data_hash"] as? String else { return nil }
            return (value,hash)
        }
    }
    private func luma(_ sample:CMSampleBuffer)->Double {
        let pixel=CMSampleBufferGetImageBuffer(sample)!
        let image=CIImage(cvPixelBuffer:pixel).applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:CGRect(x:0,y:0,width:CVPixelBufferGetWidth(pixel),height:CVPixelBufferGetHeight(pixel)))])
        var data=[UInt8](repeating:0,count:4)
        CIContext().render(image,toBitmap:&data,rowBytes:4,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        return Double(data[0])
    }

    /// Runs the complete post-download path on timestamp-preserved input with B frames and audio preroll.
    /// The process stub stands in only for the remote transfer; real FFmpeg, decoder, and export are used.
    @MainActor func testOffsetSectionMapsFramesAndExportsPreciselyWithAndWithoutAudio() async throws {
        let dir=try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let source=dir.appendingPathComponent("long.mp4")
        _=try await ImportProcess().run(executable:engine,arguments:["-v","error","-nostdin","-n","-stream_loop","4","-i",root.appendingPathComponent(".build/fixtures/cfr.mp4").path,"-c","copy",source.path])
        let section=dir.appendingPathComponent("downloaded.mkv")
        _=try await ImportProcess().run(executable:engine,arguments:["-v","error","-nostdin","-n","-ss","8.5","-t","12.5","-copyts","-start_at_zero","-i",source.path,"-c","copy",section.path])
        let tools=try stub(dir,script:"""
        printf '%s\\n' "$@" > arguments.txt
        /bin/cp '\(section.path)' source.mkv
        printf 'CLIPPER_FILE:"%s/source.mkv"\\n' "$PWD"
        """)
        let sourcePackets=try await packets(source)
        let range=try ImportRange(start:13.5,end:16)
        for muted in [false,true] {
            let imported=try await URLMediaDownload.download(url:URL(string:"https://example.com/video")!,media:info(),selector:"18",excludeAudio:muted,range:range,tools:tools,temporaryRoot:dir.appendingPathComponent("Imports")) { _ in }
            let args=try String(contentsOf:imported.directory.appendingPathComponent("arguments.txt"),encoding:.utf8).components(separatedBy:"\n")
            XCTAssertTrue(args.contains("*8.500000-21.000000"))
            XCTAssertTrue(args.contains("ffmpeg_i1:-copyts -start_at_zero"))
            XCTAssertFalse(args.contains("--force-keyframes-at-cuts"))
            let mapping=try XCTUnwrap(imported.timeline)
            XCTAssertGreaterThan(mapping.offset,7); XCTAssertLessThan(mapping.offset,8.5)
            let importedPackets=try await packets(imported.file)
            let chosenPackets=sourcePackets.filter { $0.0 >= range.start && $0.0 < range.end }
            for packet in chosenPackets {
                let match=try XCTUnwrap(importedPackets.first { abs($0.0-mapping.localOrigin+mapping.offset-packet.0) < 0.001 })
                XCTAssertEqual(match.1,packet.1,"Stream copy must preserve every packet in the requested range")
            }
            let local=try open(imported.file); defer { clip_close(local) }
            let original=try open(source); defer { clip_close(original) }
            let localInfo=clip_info(local)
            XCTAssertLessThan(localInfo.duration,14)
            XCTAssertEqual(localInfo.audioCount,muted ? 0 : 1)
            let point=clip_frame(local,mapping.local(13.5)+0.0005)
            defer { point.sample?.release() }
            let expected=clip_frame(original,13.5005)
            defer { expected.sample?.release() }
            XCTAssertEqual(mapping.original(point.time),expected.time,accuracy:0.001)
            let end=clip_frame(local,mapping.local(14.5)+0.0005)
            defer { end.sample?.release() }
            let output=dir.appendingPathComponent("export-\(muted).mp4")
            var edit=EditSettings(); edit.muted=true; edit.quality=90
            let request=ExportRequest(source:imported.file,details:details(localInfo),edit:edit,start:point.time,end:end.time+end.duration,destination:output)
            try await EncoderProcess().run(request) { _ in }
            let exported=try open(output); defer { clip_close(exported) }
            var count=0
            while true {
                let frame=clip_next(exported); defer { frame.sample?.release() }
                if frame.kind == 0 { break }
                if frame.kind == 1 {
                    let originalFrame=clip_frame(original,mapping.original(point.time+frame.time)+0.0005)
                    defer { originalFrame.sample?.release() }
                    XCTAssertEqual(luma(frame.sample!.takeUnretainedValue()),luma(originalFrame.sample!.takeUnretainedValue()),accuracy:4,"Exported frame identity")
                    count += 1
                }
            }
            XCTAssertEqual(count,25,"Inclusive last-frame boundary stays precise after offset mapping")
            let editor=Editor()
            editor.open(imported.file,temporary:imported)
            let deadline=Date().addingTimeInterval(10)
            while (editor.loading || editor.playback.seeking) && Date() < deadline { try await Task.sleep(for:.milliseconds(20)) }
            XCTAssertTrue(editor.canExport)
            XCTAssertEqual(editor.timeDisplayOffset,mapping.offset)
            XCTAssertEqual(try XCTUnwrap(editor.localTime(13.5)),mapping.local(13.5),accuracy:0.000001)
            XCTAssertNil(editor.localTime(1))
            editor.close()
            await withCheckedContinuation { c in editor.playback.queue.async { c.resume() } }
        }
    }

    func testCancellationRemovesPartialSection() async throws {
        let dir=try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let ready=expectation(description:"partial file created")
        let tools=try stub(dir,script:"touch source.part; echo 'CLIPPER_POST:started'; sleep 30")
        let destination=dir.appendingPathComponent("Imports")
        let media=try info()
        let job=Task {
            try await URLMediaDownload.download(url:URL(string:"https://example.com/video")!,media:media,selector:"18",range:ImportRange(start:13.5,end:16),tools:tools,temporaryRoot:destination) { update in
                if update.label == "Preparing downloaded media…" { ready.fulfill() }
            }
        }
        await fulfillment(of:[ready],timeout:5)
        job.cancel()
        do { _=try await job.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:destination.path),[])
    }

    func testRebasedOrTruncatedDownloadsAreRejectedAndCleaned() async throws {
        let dir=try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let tools=try stub(dir,script:"""
        /bin/cp '\(root.appendingPathComponent(".build/fixtures/cfr.mp4").path)' source.mp4
        printf 'CLIPPER_FILE:"%s/source.mp4"\\n' "$PWD"
        """)
        let destination=dir.appendingPathComponent("Imports")
        do {
            _=try await URLMediaDownload.download(url:URL(string:"https://example.com/video")!,media:info(),selector:"18",range:ImportRange(start:80,end:85),tools:tools,temporaryRoot:destination) { _ in }
            XCTFail("A rebased download must never get a guessed original timestamp")
        } catch { XCTAssertTrue(error.localizedDescription.contains("original timestamps")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:destination.path),[])
    }
}
