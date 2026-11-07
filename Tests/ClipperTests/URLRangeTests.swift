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
            "--download-sections","*475.000000-515.250000","--downloader-args","ffmpeg_i:-copyts -start_at_zero -protocol_whitelist http,https,tcp,tls,crypto -rw_timeout 30000000",
            "--downloader-args","ffmpeg_o:-sn -dn -f matroska","--fixup","never"])
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
            XCTAssertTrue(args.contains("ffmpeg_i:-copyts -start_at_zero -protocol_whitelist http,https,tcp,tls,crypto -rw_timeout 30000000"))
            XCTAssertTrue(args.contains("ffmpeg_o:-sn -dn -f matroska"))
            XCTAssertTrue(args.contains("never"))
            XCTAssertTrue(args.contains(imported.directory.appendingPathComponent("source.mkv").path))
            XCTAssertFalse(args.joined().contains("tls_verify"))
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
            XCTAssertEqual(try XCTUnwrap(editor.localTime(999)),editor.details!.duration-0.000001,accuracy:0.000001)
            editor.close()
            await withCheckedContinuation { c in editor.playback.queue.async { c.resume() } }
        }
    }

    @MainActor func testRealDownloaderAgainstHTTPFixtures() async throws {
        guard ProcessInfo.processInfo.environment["CLIPPER_RANGE_NETWORK_TEST"] == "1" else {
            throw XCTSkip("Opt-in real yt-dlp and loopback HTTP integration test")
        }
        let dir=try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let long=dir.appendingPathComponent("long.mp4")
        _=try await ImportProcess().run(executable:engine,arguments:["-v","error","-nostdin","-n","-stream_loop","4","-i",root.appendingPathComponent(".build/fixtures/cfr.mp4").path,"-c","copy",long.path])
        for (file,options) in [("offset.mp4",["-output_ts_offset","10"]),("offset.ts",["-output_ts_offset","10"]),("video.mp4",["-map","0:v:0"]),("audio.m4a",["-map","0:a:0"])] {
            _=try await ImportProcess().run(executable:engine,arguments:["-v","error","-nostdin","-n","-i",long.path,"-c","copy"]+options+[dir.appendingPathComponent(file).path])
        }
        var names=["long.mp4","offset.mp4","offset.ts"]
        let fixtureEngine=URL(fileURLWithPath:"/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
        if FileManager.default.isExecutableFile(atPath:fixtureEngine.path) {
            let subtitles=dir.appendingPathComponent("captions.srt")
            try Data("1\n00:00:00,000 --> 00:00:29,000\nCaption fixture\n".utf8).write(to:subtitles)
            _=try await ImportProcess().run(executable:fixtureEngine,arguments:["-v","error","-nostdin","-n","-i",long.path,"-i",subtitles.path,"-c:v","copy","-c:a","copy","-c:s","mov_text","-timecode","01:00:00:00",dir.appendingPathComponent("tracks.mp4").path])
            names.append("tracks.mp4")
        }
        let server=Process(), output=Pipe()
        server.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments=["-I",root.appendingPathComponent("scripts/range-fixture-server.py").path,dir.path]
        server.standardOutput=output; server.standardError=FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        var line=Data()
        while let byte=try output.fileHandleForReading.read(upToCount:1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
        let port=try XCTUnwrap(Int(String(decoding:line,as:UTF8.self)))
        let base="http://127.0.0.1:\(port)"
        let toolRoot=root.appendingPathComponent(".build/range-tests/Tools")
        let tools=ImportTools(ytDLP:toolRoot.appendingPathComponent("yt-dlp"),deno:toolRoot.appendingPathComponent("deno"),ffmpegDirectory:engine.deletingLastPathComponent(),version:"2026.10.26",notice:nil)
        let range=try ImportRange(start:13.5,end:16)
        for name in names {
            let url=URL(string:base+"/"+name)!
            let media=try await URLMediaDownload.inspect(url:url,tools:tools)
            let imported=try await URLMediaDownload.download(url:url,media:media,selector:media.selector(video:"best",audio:"best"),range:range,tools:tools,temporaryRoot:dir.appendingPathComponent("Imports")) { _ in }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:imported.directory.path),[imported.file.lastPathComponent])
            XCTAssertEqual(imported.file.pathExtension,"mkv")
            let probe=try await ImportProbe.read(file:imported.file,tools:tools)
            XCTAssertTrue(probe.streams?.allSatisfy { ["video","audio"].contains($0.codec_type ?? "") } == true)
            let mapping=try XCTUnwrap(imported.timeline)
            let originalProbe=try await ImportProbe.read(file:dir.appendingPathComponent(name),tools:tools)
            let sourcePackets=try await packets(dir.appendingPathComponent(name))
            let resultPackets=try await packets(imported.file)
            for packet in sourcePackets where packet.0-(originalProbe.start ?? 0) >= range.start && packet.0-(originalProbe.start ?? 0) < range.end {
                let match=try XCTUnwrap(resultPackets.first { abs($0.0-mapping.localOrigin+mapping.offset-(packet.0-(originalProbe.start ?? 0))) < 0.002 },name)
                // MPEG-TS changes packet framing, but the MP4-to-MKV copies retain hashes.
                if name != "offset.ts" { XCTAssertEqual(match.1,packet.1,name) }
            }
            imported.dispose()
        }
        // Feed actual yt-dlp a two-input format manifest, using the production download arguments.
        let manifest=dir.appendingPathComponent("formats.json")
        let json:[String:Any]=["id":"split","title":"Split streams","duration":30,"extractor":"generic","webpage_url":base+"/video", "formats":[
            ["format_id":"v","url":base+"/video.mp4","ext":"mp4","vcodec":"h264","acodec":"none","protocol":"http"],
            ["format_id":"a","url":base+"/audio.m4a","ext":"m4a","vcodec":"none","acodec":"aac","protocol":"http"]]]
        try JSONSerialization.data(withJSONObject:json).write(to:manifest)
        let wrapper=dir.appendingPathComponent("yt-dlp-fixture")
        let script="""
        #!/usr/bin/python3 -I
        import os, sys
        args = sys.argv[1:]
        args = args[:args.index('--')]
        os.execv('\(tools.ytDLP.path)', ['\(tools.ytDLP.path)', '--load-info-json', '\(manifest.path)'] + args)
        """
        try Data(script.utf8).write(to:wrapper)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let splitTools=ImportTools(ytDLP:wrapper,deno:tools.deno,ffmpegDirectory:tools.ffmpegDirectory,version:tools.version,notice:nil)
        let media=try URLMedia.decode(JSONSerialization.data(withJSONObject:json))
        let imported=try await URLMediaDownload.download(url:URL(string:base+"/video")!,media:media,selector:"v+a",range:range,tools:splitTools,temporaryRoot:dir.appendingPathComponent("Imports")) { _ in }
        defer { imported.dispose() }
        let mapping=try XCTUnwrap(imported.timeline)
        let result=try open(imported.file); defer { clip_close(result) }
        XCTAssertEqual(clip_info(result).audioCount,1)
        let point=clip_frame(result,mapping.local(13.5)); defer { point.sample?.release() }
        XCTAssertEqual(mapping.original(point.time),13.5,accuracy:0.05)
    }

    func testRepresentativePublicURLRange() async throws {
        guard ProcessInfo.processInfo.environment["CLIPPER_RANGE_PUBLIC_TEST"] == "1" else {
            throw XCTSkip("Opt-in public HTTPS ranged download")
        }
        let dir=try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let toolRoot=root.appendingPathComponent(".build/range-tests/Tools")
        let tools=ImportTools(ytDLP:toolRoot.appendingPathComponent("yt-dlp"),deno:toolRoot.appendingPathComponent("deno"),ffmpegDirectory:engine.deletingLastPathComponent(),version:"2026.10.26",notice:nil)
        let url=URL(string:"https://download.blender.org/peach/trailer/trailer_iphone.m4v")!
        let media=try await URLMediaDownload.inspect(url:url,tools:tools)
        let imported=try await URLMediaDownload.download(url:url,media:media,selector:media.selector(video:"best",audio:"best"),range:ImportRange(start:20,end:25),tools:tools,temporaryRoot:dir) { _ in }
        defer { imported.dispose() }
        XCTAssertNotNil(imported.timeline)
        let decoder=try open(imported.file); defer { clip_close(decoder) }
        XCTAssertLessThan(clip_info(decoder).duration,20)
    }

    func testNetworkBuildRejectsBadCertificatesByDefault() async throws {
        guard ProcessInfo.processInfo.environment["CLIPPER_RANGE_NETWORK_TEST"] == "1" else { throw XCTSkip("Opt-in loopback TLS test") }
        let help=try await ImportProcess().run(executable:engine,arguments:["-hide_banner","-h","protocol=tls"])
        XCTAssertTrue(String(decoding:help,as:UTF8.self).contains("(default 1)"))
        let dir=try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let cert=dir.appendingPathComponent("cert.pem"), key=dir.appendingPathComponent("key.pem")
        _=try await ImportProcess().run(executable:URL(fileURLWithPath:"/usr/bin/openssl"),arguments:["req","-x509","-newkey","rsa:2048","-nodes","-subj","/CN=localhost","-keyout",key.path,"-out",cert.path,"-days","1"])
        let server=Process(), output=Pipe()
        server.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments=["-I",root.appendingPathComponent("scripts/range-fixture-server.py").path,dir.path,cert.path,key.path]
        server.standardOutput=output; server.standardError=FileHandle.nullDevice
        try server.run(); defer { server.terminate(); server.waitUntilExit() }
        var line=Data()
        while let byte=try output.fileHandleForReading.read(upToCount:1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
        let port=try XCTUnwrap(Int(String(decoding:line,as:UTF8.self)))
        do {
            _=try await ImportProcess().run(executable:engine,arguments:["-v","error","-nostdin","-rw_timeout","5000000","-i","https://127.0.0.1:\(port)/","-f","null","-"])
            XCTFail("An untrusted TLS peer must fail without CLI verification flags")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("-9807"),error.localizedDescription)
        }
    }

    func testRoundedDurationAtSourceEndAndAudioPrerollAtStart() async throws {
        let dir=try directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let normalized=dir.appendingPathComponent("edge.mkv")
        _=try await ImportProcess().run(executable:engine,arguments:["-v","error","-nostdin","-n","-ss","0.5","-t","3","-i",root.appendingPathComponent(".build/fixtures/cfr.mp4").path,"-c","copy",normalized.path])
        let decoder=try open(normalized); defer { clip_close(decoder) }
        let info=clip_info(decoder), first=clip_frame(decoder,0)
        defer { first.sample?.release() }
        let range=try ImportRange(start:0,end:info.duration+0.05)
        try await ImportProbe.verify(file:normalized,range:range,offset:info.origin,expectedOrigin:info.origin,sourceDuration:range.end)
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
