import XCTest
import CMedia
import AppKit
import CoreVideo
import CoreMedia
import CoreImage
@testable import Clipper

final class SubtitleTests:XCTestCase {
    let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
    var fixtures:URL { root.appendingPathComponent(".build/fixtures/subtitles") }
    func fixture(_ name:String)->URL { fixtures.appendingPathComponent(name) }
    func details(_ name:String="black.mp4") throws -> MediaDetails {
        var error=[CChar](repeating:0,count:512)
        let media=try XCTUnwrap(clip_open(fixture(name).path,-1,&error,512),String(cString:error))
        defer { clip_close(media) }; let i=clip_info(media)
        return MediaDetails(duration:i.duration,origin:i.origin,width:Int(i.width),height:Int(i.height),rotation:i.rotation,pixelAspect:i.pixelAspect,fps:i.fps,hdr:i.hdr != 0,codec:"h264",audioLabels:[],audioStreams:[],colorSpace:Int(i.colorSpace))
    }
    @MainActor func wait(_ condition:@escaping @MainActor ()->Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds:20_000_000) }
        XCTFail("Timed out waiting for subtitles")
    }
    func testComposerRemovesPositionDrawingsHiddenAndDuplicates() {
        let input="""
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:02.00,0:00:04.00,Fancy,,40,40,60,Scroll up,{\( "\\pos(100,80)\\c&HFF0000&\\b700\\i1" )}Hello\\Nworld
        Dialogue: 1,0:00:02.00,0:00:04.00,Fancy,,0,0,0,,{\\b1\\i1}Hello\\Nworld
        Dialogue: 0,0:00:02.00,0:00:04.00,Fancy,,0,0,0,,{\\p1}m 0 0 l 3 3
        Dialogue: 0,0:00:02.00,0:00:04.00,Fancy,,0,0,0,,{\\alpha&HFF&}Hidden
        Comment: 0,0:00:02.00,0:00:04.00,Fancy,,0,0,0,,Comment
        """
        let result=SubtitleComposer.compose(input,style:SubtitleStyle(),width:360,height:640)
        XCTAssertTrue(result.contains("PlayResX: 360")); XCTAssertTrue(result.contains("YCbCr Matrix: None"))
        XCTAssertTrue(result.contains("Default,Helvetica Neue,18.00"))
        XCTAssertFalse(result.contains("pos(")); XCTAssertFalse(result.contains("Hidden")); XCTAssertFalse(result.contains("m 0"))
        XCTAssertEqual(result.components(separatedBy:"Dialogue:").count-1,1)
        XCTAssertTrue(result.contains("{\\b1\\i1}Hello\\Nworld"))
    }
    func testEncodingAndManagedCleanup() throws {
        XCTAssertEqual(try SubtitleComposer.decode(Data("Polski żółć".utf8)),"Polski żółć")
        XCTAssertEqual(try SubtitleComposer.decode(Data([0xFF,0xFE,0x41,0])),"A")
        XCTAssertThrowsError(try SubtitleComposer.decode(Data([0x80,0xFF])))
        var directory:SubtitleDirectory?=try SubtitleDirectory(); let url=directory!.url
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path)); directory=nil
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
    func testCatalogOneMultipleDefaultsAndFontAttachment() throws {
        let dir=try SubtitleDirectory()
        let c=try XCTUnwrap(clip_subtitle_catalog(fixture("attached-font.mkv").path,dir.url.appendingPathComponent("fonts").path))
        defer { clip_subtitle_catalog_free(c) }
        XCTAssertEqual(clip_subtitle_count(c),2); XCTAssertNotEqual(clip_subtitle_stream(c,0),clip_subtitle_stream(c,1))
        XCTAssertNotEqual(clip_subtitle_default(c,0),0)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:dir.url.appendingPathComponent("fonts").path).isEmpty)
        let one=try XCTUnwrap(clip_subtitle_catalog(fixture("one-track.mkv").path,nil)); defer { clip_subtitle_catalog_free(one) }
        XCTAssertEqual(clip_subtitle_count(one),1)
    }
    @MainActor func controller(_ file:String,video:String="black.mp4") async throws -> SubtitleController {
        let c=SubtitleController(); c.open(fixture(video),details:try details(video))
        // Catalog completion is independent of the initial track list.
        try await wait { !c.scanning }
        c.external=fixture(file); c.sourceKind = .external; c.enabled=true; c.prepare()
        try await wait { !c.preparing }; XCTAssertNil(c.message)
        return c
    }
    @MainActor func testSRTVTTASSAndSSAAreRealRenderableSources() async throws {
        for file in ["dialogue.srt","dialogue.vtt","styled.ass","styled.ssa"] {
            let c=try await controller(file)
            let asset=try XCTUnwrap(c.render)
            let r=try XCTUnwrap(clip_subtitles_open(asset.file.path,asset.fonts.path)); defer { clip_subtitles_free(r) }
            XCTAssertGreaterThan(clip_subtitles_events(r),0)
            var x:Int32=0,y:Int32=0,changed:Int32=0
            XCTAssertNil(clip_subtitles_render(r,1000,640,360,&x,&y,&changed))
            let image=clip_subtitles_render(r,2500,640,360,&x,&y,&changed)?.takeRetainedValue()
            XCTAssertNotNil(image,file); XCTAssertGreaterThan(image?.width ?? 0,10)
            c.reset()
        }
    }
    @MainActor func testLateCueRetainsTimingAndMissingUnsupportedFilesBlock() async throws {
        let c=try await controller("dialogue.srt")
        let asset=try XCTUnwrap(c.render),text=try String(contentsOf:asset.file,encoding:.utf8)
        XCTAssertTrue(text.contains("0:01:00.00"),text)
        c.external=fixture("missing.srt"); c.prepare(); try await wait { !c.preparing }
        XCTAssertFalse(c.ready); XCTAssertTrue(c.message?.contains("missing") == true)
        c.external=fixture("unsupported.sub"); c.prepare(); try await wait { !c.preparing }
        XCTAssertFalse(c.ready); XCTAssertTrue(c.message?.contains("Unsupported") == true)
        c.reset(); XCTAssertNil(c.external); XCTAssertNil(c.render); XCTAssertFalse(c.enabled)
    }
    @MainActor func testOverrideAndGeometryAndSelectionRetention() async throws {
        let c=try await controller("styled.ass")
        XCTAssertTrue(c.render?.preserve == true)
        c.overrideStyle=true; c.style.color="FF0000"
        var edit=EditSettings(); edit.cropPreset = .vertical; edit.setCrop(ratio:9/16,size:try details().displaySize)
        c.rebuild(details:try details(),edit:edit)
        let text=try String(contentsOf:XCTUnwrap(c.render).file,encoding:.utf8)
        XCTAssertFalse(c.render?.preserve ?? true); XCTAssertFalse(text.contains("pos(")); XCTAssertTrue(text.contains("&H000000FF"))
        XCTAssertEqual(c.external,fixture("styled.ass"))
    }
    @MainActor func testExportTimingAndHDRPolicy() async throws {
        let c=try await controller("dialogue.srt",video:"offset-tracks.mkv")
        let d=try details("offset-tracks.mkv"),asset=try XCTUnwrap(c.render)
        XCTAssertEqual(asset.zero,d.origin)
        var request=ExportRequest(source:fixture("offset-tracks.mkv"),details:d,edit:EditSettings(),start:1,end:5,destination:fixture("unused.mp4"),subtitles:asset)
        let args=try request.arguments(),vf=try XCTUnwrap(args.firstIndex(of:"-vf")).advanced(by:1)
        XCTAssertTrue(args[vf].contains("ass=filename=")); XCTAssertTrue(args.contains("-allow_sw")); XCTAssertEqual(args[args.firstIndex(of:"-allow_sw")!+1],"0")
        var hdr=d; hdr.hdr=true; request=ExportRequest(source:request.source,details:hdr,edit:request.edit,start:1,end:5,destination:request.destination,subtitles:asset)
        XCTAssertThrowsError(try request.arguments())
        var edit=request.edit; edit.convertToSDR=true
        request=ExportRequest(source:request.source,details:hdr,edit:edit,start:1,end:5,destination:request.destination,subtitles:asset)
        XCTAssertTrue(try request.arguments().contains("bt709"))
        let f=FramePoint(time:2,duration:1/24,pts:288000,timeBaseNum:1,timeBaseDen:24000)
        XCTAssertEqual(asset.milliseconds(frame:f,relativeTime:2,origin:10),2000)
    }
    func run(_ arguments:[String]) throws {
        let p=Process(); p.executableURL=SubtitleProcess.executable; p.arguments=["-v","error","-y"]+arguments
        let pipe=Pipe(); p.standardError=pipe; try p.run(); let data=pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus,0,String(decoding:data,as:UTF8.self))
    }
    func luminance(_ url:URL,time:Double) throws -> [UInt8] {
        var error=[CChar](repeating:0,count:512)
        let media=try XCTUnwrap(clip_open(url.path,-1,&error,512))
        defer { clip_close(media) }
        let sample=try XCTUnwrap(clip_frame(media,time).sample?.takeRetainedValue())
        let pixel=try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(pixel,.readOnly); defer { CVPixelBufferUnlockBaseAddress(pixel,.readOnly) }
        let width=CVPixelBufferGetWidth(pixel),height=CVPixelBufferGetHeight(pixel)
        let base=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel,0)).assumingMemoryBound(to:UInt8.self)
        let stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,0)
        return (0..<height).flatMap { row in (0..<width).map { col in
            UInt8(max(0,min(255,(Double(base[row*stride+col])-16)*255/219)))
        } }
    }

    @MainActor func testActualHardwareExportCueBoundariesCropAndRendererParity() async throws {
        let c=try await controller("dialogue.srt")
        let d=try details(); var edit=EditSettings(); edit.quality=90; edit.cropPreset = .vertical; edit.setCrop(ratio:9/16,size:d.displaySize)
        c.rebuild(details:d,edit:edit)
        let asset=try XCTUnwrap(c.render),dir=try SubtitleDirectory(),output=dir.url.appendingPathComponent("clip.mp4")
        let request=ExportRequest(source:fixture("black.mp4"),details:d,edit:edit,start:1,end:5,destination:output,subtitles:asset)
        try await EncoderProcess().run(request) { _ in }
        let before=try luminance(output,time:0.5),during=try luminance(output,time:1.5),after=try luminance(output,time:3.5)
        XCTAssertLessThan(before.max() ?? 255,30); XCTAssertGreaterThan(during.max() ?? 0,180); XCTAssertLessThan(after.max() ?? 255,30)
        let g=edit.geometry(for:d),r=try XCTUnwrap(clip_subtitles_open(asset.file.path,asset.fonts.path)); defer { clip_subtitles_free(r) }
        var x:Int32=0,y:Int32=0,changed:Int32=0
        let image=try XCTUnwrap(clip_subtitles_render(r,2500,Int32(g.outWidth),Int32(g.outHeight),&x,&y,&changed)?.takeRetainedValue())
        XCTAssertGreaterThan(Int(y),g.outHeight/2)
        let bytes=CFDataGetBytePtr(image.dataProvider!.data!)!
        var error=0.0,count=0
        for row in 0..<image.height { for col in 0..<image.width {
            let i=row*image.bytesPerRow+col*4
            let expected=Double(bytes[i])*0.2126+Double(bytes[i+1])*0.7152+Double(bytes[i+2])*0.0722
            let actual=Double(during[(Int(y)+row)*g.outWidth+Int(x)+col])
            error += abs(expected-actual); count += 1
        } }
        XCTAssertLessThan(error/Double(count),15,"Live libass overlay and burned-in output should match")
    }
    @MainActor func testEmbeddedOriginAndSourceCleanup() async throws {
        let d=try details("offset-tracks.mkv"),c=SubtitleController()
        c.open(fixture("offset-tracks.mkv"),details:d)
        try await wait { c.tracks.count==2 }
        c.enabled=true; c.sourceKind = .container; c.track=c.tracks[0].id; c.prepare()
        try await wait { !c.preparing }
        let asset=try XCTUnwrap(c.render)
        XCTAssertEqual(asset.zero,0)
        XCTAssertTrue(try String(contentsOf:asset.file,encoding:.utf8).contains("0:00:12.00"))
        c.reset(); XCTAssertTrue(c.tracks.isEmpty); XCTAssertNil(c.render)
    }
}

extension SubtitleTests {
    @MainActor func testHDRToSDRWithVisibleSubtitlesAndVideoTags() async throws {
        let c=try await controller("dialogue.srt")
        let d=try details(); var hdr=d; hdr.hdr=true
        // Use the existing real PQ fixture, with a cue inside its two-second duration.
        let hdrURL=root.appendingPathComponent(".build/fixtures/hdr.mp4")
        var error=[CChar](repeating:0,count:512)
        let media=try XCTUnwrap(clip_open(hdrURL.path,-1,&error,512)); let info=clip_info(media); clip_close(media)
        hdr.width=Int(info.width); hdr.height=Int(info.height); hdr.duration=info.duration; hdr.origin=info.origin
        let dir=try SubtitleDirectory()
        let original=try String(contentsOf:XCTUnwrap(c.render).file,encoding:.utf8)
        let text=original.replacingOccurrences(of:"0:00:02.00",with:"0:00:00.00").replacingOccurrences(of:"0:00:04.00",with:"0:00:01.50")
        let asset=try RenderSubtitles(directory:dir,text:text,zero:hdr.origin,preserve:false)
        var edit=EditSettings(); edit.convertToSDR=true
        let output=dir.url.appendingPathComponent("hdr-sdr.mp4")
        try await EncoderProcess().run(ExportRequest(source:hdrURL,details:hdr,edit:edit,start:0,end:1.5,destination:output,subtitles:asset)) { _ in }
        let decoded=try XCTUnwrap(clip_open(output.path,-1,&error,512)); defer { clip_close(decoded) }
        XCTAssertEqual(clip_info(decoded).hdr,0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:output.path))
    }
    @MainActor func testRotationVFRAndOffsetExportsKeepCues() async throws {
        let c=try await controller("dialogue.srt")
        for name in ["rotated.mp4","vfr.mkv","offset.mkv"] {
            let source=root.appendingPathComponent(".build/fixtures/"+name)
            var error=[CChar](repeating:0,count:512)
            let media=try XCTUnwrap(clip_open(source.path,-1,&error,512)),i=clip_info(media); clip_close(media)
            let d=MediaDetails(duration:i.duration,origin:i.origin,width:Int(i.width),height:Int(i.height),rotation:i.rotation,pixelAspect:i.pixelAspect,fps:i.fps,hdr:false,codec:"h264",audioLabels:[],audioStreams:[])
            let dir=try SubtitleDirectory(),text=try String(contentsOf:XCTUnwrap(c.render).file,encoding:.utf8)
            let asset=try RenderSubtitles(directory:dir,text:text,zero:d.origin,preserve:false)
            let output=dir.url.appendingPathComponent("result.mp4")
            try await EncoderProcess().run(ExportRequest(source:source,details:d,edit:EditSettings(),start:1,end:4.5,destination:output,subtitles:asset)) { _ in }
            let baseline=dir.url.appendingPathComponent("baseline.mp4")
            try await EncoderProcess().run(ExportRequest(source:source,details:d,edit:EditSettings(),start:1,end:4.5,destination:baseline)) { _ in }
            let baselineBefore=try luminance(baseline,time:0.5),baselineDuring=try luminance(baseline,time:1.5),baselineAfter=try luminance(baseline,time:3.25)
            let before=try luminance(output,time:0.5),during=try luminance(output,time:1.5),after=try luminance(output,time:3.25)
            XCTAssertLessThan(abs(Int(before.max() ?? 0)-Int(baselineBefore.max() ?? 0)),6,name)
            XCTAssertGreaterThan(Int(during.max() ?? 0),Int(baselineDuring.max() ?? 0)+40,name)
            XCTAssertLessThan(abs(Int(after.max() ?? 0)-Int(baselineAfter.max() ?? 0)),6,name)
        }
    }
    @MainActor func testEnablingDuringCatalogDoesNotCancelDiscovery() async throws {
        let c=SubtitleController(); c.open(fixture("two-tracks.mkv"),details:try details("two-tracks.mkv"))
        c.enabled=true; c.prepare()
        try await wait { !c.scanning && !c.preparing }
        XCTAssertEqual(c.tracks.count,2); XCTAssertNotNil(c.render); XCTAssertTrue(c.ready)
        var asset:RenderSubtitles?=c.render; let directory=try XCTUnwrap(asset).directory.url
        c.reset(); asset=nil
        try await wait { !FileManager.default.fileExists(atPath:directory.path) }
    }
}

extension SubtitleTests {
    @MainActor func testUnchangedSettingsReuseAssetAndSpoofedSRTIsRejected() async throws {
        let c=try await controller("dialogue.srt")
        c.rebuild(details:try details(),edit:EditSettings())
        let identity=try XCTUnwrap(c.render).identity
        var edit=EditSettings(); edit.quality=80; edit.muted=true
        c.rebuild(details:try details(),edit:edit)
        XCTAssertEqual(c.render?.identity,identity)
        let spoof=fixture("spoof-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at:spoof) }
        try "#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXTINF:8,\nblack.mp4\n#EXT-X-ENDLIST\n".write(to:spoof,atomically:true,encoding:.utf8)
        c.external=spoof; c.prepare(); try await wait { !c.preparing }
        XCTAssertNil(c.render); XCTAssertNotNil(c.message)
    }
    @MainActor func testColoredSubtitleOnUntaggedHDMatchesRGBPreview() async throws {
        let d=try details("hd-untagged.mp4"),c=try await controller("dialogue.srt")
        XCTAssertEqual(d.colorSpace,2)
        c.style.color="FF0000"; c.style.outline=0; c.style.shadow=0
        c.rebuild(details:d,edit:EditSettings())
        let asset=try XCTUnwrap(c.render),dir=try SubtitleDirectory(),output=dir.url.appendingPathComponent("color.mp4")
        let request=ExportRequest(source:fixture("hd-untagged.mp4"),details:d,edit:EditSettings(),start:1,end:5,destination:output,subtitles:asset)
        XCTAssertTrue(try request.arguments().contains(where:{$0.contains("setparams=colorspace=bt709")}))
        try await EncoderProcess().run(request) { _ in }
        var error=[CChar](repeating:0,count:512)
        let media=try XCTUnwrap(clip_open(output.path,-1,&error,512)); defer { clip_close(media) }
        XCTAssertEqual(clip_info(media).colorSpace,1)
        let sample=try XCTUnwrap(clip_frame(media,1.5).sample?.takeRetainedValue())
        let pixel=try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        let context=CIContext(),image=CIImage(cvPixelBuffer:pixel)
        var rgba=[UInt8](repeating:0,count:d.width*d.height*4)
        context.render(image,toBitmap:&rgba,rowBytes:d.width*4,bounds:image.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        var brightRed=0
        for i in stride(from:0,to:rgba.count,by:4) where rgba[i]>200 && rgba[i+1]<40 && rgba[i+2]<40 { brightRed += 1 }
        XCTAssertGreaterThan(brightRed,100,"Saturated red in the preview must remain red after YUV blending")
    }
    @MainActor func testEmbeddedOffsetBurnsAtTheSameRelativeTime() async throws {
        let d=try details("offset-tracks.mkv"),c=SubtitleController(); c.open(fixture("offset-tracks.mkv"),details:d)
        try await wait { !c.scanning }; c.enabled=true; c.sourceKind = .container; c.prepare(); try await wait { !c.preparing }
        c.rebuild(details:d,edit:EditSettings())
        let dir=try SubtitleDirectory(),output=dir.url.appendingPathComponent("embedded.mp4")
        try await EncoderProcess().run(ExportRequest(source:fixture("offset-tracks.mkv"),details:d,edit:EditSettings(),start:1,end:5,destination:output,subtitles:try XCTUnwrap(c.render))) { _ in }
        XCTAssertLessThan(try luminance(output,time:0.5).max() ?? 255,30)
        XCTAssertGreaterThan(try luminance(output,time:1.5).max() ?? 0,180)
        XCTAssertLessThan(try luminance(output,time:3.5).max() ?? 255,30)
    }
}
