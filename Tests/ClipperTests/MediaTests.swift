import XCTest
import CMedia
import CoreImage
import AVFoundation
import Combine
@testable import Clipper

final class MediaTests:XCTestCase {
    @MainActor func testSaveAsAcceptsConfirmedExistingOutput() throws {
        let directory=fixture("replace-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("source.mp4"), output=directory.appendingPathComponent("output.mp4")
        try Data("source".utf8).write(to:source)
        try Data("old output".utf8).write(to:output)
        let validator=ExportSavePanelValidator(source:source)
        XCTAssertNoThrow(try validator.panel(NSObject(),validate:output),"An existing output must pass the panel's validator after macOS confirms replacement")
        XCTAssertThrowsError(try validator.panel(NSObject(),validate:source))
    }
    func testExportProtectsSourceThroughSymlinksAndHardLinks() throws {
        let directory=fixture("source-protection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("source.mp4"), symbolic=directory.appendingPathComponent("symbolic.mp4"), hard=directory.appendingPathComponent("hard.mp4")
        let original=Data("original source".utf8)
        try original.write(to:source)
        try FileManager.default.createSymbolicLink(at:symbolic,withDestinationURL:source)
        try FileManager.default.linkItem(at:source,to:hard)
        for destination in [source,symbolic,hard,directory.appendingPathComponent("./source.mp4")] {
            XCTAssertThrowsError(try ExportDestination.validate(source:source,destination:destination))
        }
        XCTAssertEqual(try Data(contentsOf:source),original)
    }
    func testPublishingDoesNotReplaceWithoutConsentOrWhenNewFileIsMissing() throws {
        let directory=fixture("publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("source.mp4"), output=directory.appendingPathComponent("output.mp4"), temporary=directory.appendingPathComponent("temporary.mp4")
        let original=Data("source".utf8), existing=Data("existing output".utf8)
        try original.write(to:source); try existing.write(to:output)
        XCTAssertThrowsError(try ExportDestination.publish(temporary,to:output,source:source,replacingExisting:true))
        XCTAssertEqual(try Data(contentsOf:output),existing)
        try Data("new output".utf8).write(to:temporary)
        XCTAssertThrowsError(try ExportDestination.publish(temporary,to:output,source:source,replacingExisting:false))
        XCTAssertEqual(try Data(contentsOf:output),existing)
        XCTAssertThrowsError(try ExportDestination.publish(temporary,to:source,source:source,replacingExisting:true))
        XCTAssertEqual(try Data(contentsOf:source),original)
    }
    @MainActor func testConfirmedExportReplacesOnlyAfterSuccessAndCancellationKeepsOutput() async throws {
        let directory=fixture("replace-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let source=directory.appendingPathComponent("source.mp4"), output=directory.appendingPathComponent("output.mp4")
        try FileManager.default.copyItem(at:fixture("cfr.mp4"),to:source)
        let sourceData=try Data(contentsOf:source), previous=Data("previous output".utf8)
        try previous.write(to:output)
        let editor=Editor(); editor.open(source)
        try await waitUntil { !editor.loading && !editor.playback.seeking }
        editor.markEnd(0.99)
        try await waitUntil { !editor.playback.seeking }
        editor.export(to:output,replacingExisting:true)
        XCTAssertEqual(try Data(contentsOf:output),previous,"The old output remains during rendering")
        try await waitUntil({ !editor.exporting },timeout:12)
        XCTAssertNil(editor.error); XCTAssertEqual(editor.lastExport,output)
        let encoded=try Data(contentsOf:output)
        XCTAssertNotEqual(encoded,previous)
        XCTAssertEqual(try frames(output).count,24)
        editor.export(to:output,replacingExisting:true); editor.cancel()
        try await waitUntil { !editor.exporting }
        XCTAssertEqual(try Data(contentsOf:output),encoded,"Cancel must keep the completed previous output")
        XCTAssertEqual(try Data(contentsOf:source),sourceData)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:directory.path).contains(where:{$0.hasPrefix(".clipper-")}))
        editor.close()
    }
    final class ObservedVideoLayer:AVSampleBufferDisplayLayer {
        var imageRemovals=0
        override func flushAndRemoveImage() { imageRemovals += 1; super.flushAndRemoveImage() }
    }
    @MainActor func testPlayPauseRetainsImageAndResumesWithoutSeeking() async throws {
        let layer=ObservedVideoLayer()
        // Use the same real renderer implementation, observing only image removal.
        let playback=Playback(video:layer)
        let ready=expectation(description:"Opened")
        playback.open(fixture("cfr.mp4"),at:2,completion:{ready.fulfill()})
        await fulfillment(of:[ready],timeout:4)
        let removals=layer.imageRemovals
        playback.play()
        try await waitUntil { playback.clock.rate>0 }
        XCTAssertEqual(layer.imageRemovals,removals,"Playing must keep the paused image visible during preparation")
        try await Task.sleep(nanoseconds:150_000_000)
        playback.pauseAndResolve()
        XCTAssertFalse(playback.seeking,"Pause resolves from decoded playback frames without a demuxer seek")
        try await waitUntil { !playback.seeking }
        let paused=playback.position
        let start=Date()
        playback.play()
        try await waitUntil { playback.clock.rate>0 }
        XCTAssertLessThan(Date().timeIntervalSince(start),0.12,"Warm resume should start immediately")
        XCTAssertGreaterThanOrEqual(playback.position,paused)
        XCTAssertEqual(layer.imageRemovals,removals)
        playback.close()
    }
    @MainActor func testCancellingPlaybackStartupAllowsTheNextPlay() async throws {
        let p=Playback(), opened=expectation(description:"Opened")
        p.open(fixture("cfr.mp4"),at:2,completion:{opened.fulfill()})
        await fulfillment(of:[opened],timeout:4)
        p.play(); p.pause()
        XCTAssertFalse(p.starting); XCTAssertFalse(p.playing)
        p.play()
        try await waitUntil { p.clock.rate>0 && !p.starting }
        p.close()
    }
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func fixture(_ name:String)->URL { root.appendingPathComponent(".build/fixtures/"+name) }
    func open(_ url:URL) throws -> OpaquePointer {
        var error=[CChar](repeating:0,count:512)
        guard let m=clip_open(url.path,0,&error,512) else { throw ExportFailure.message(String(cString:error)) }; return m
    }
    func frames(_ url:URL) throws -> [(Double,Double)] {
        let m=try open(url); defer { clip_close(m) }
        var values:[(Double,Double)]=[]
        while true {
            let sample=clip_next(m)
            if sample.kind == 0 { break }
            XCTAssertGreaterThan(sample.kind,0,"Decode failed for \(url.lastPathComponent)")
            if sample.kind < 0 { break }
            if let unmanaged=sample.sample {
                let buffer=unmanaged.takeRetainedValue()
                if sample.kind == 1 { values.append((sample.time,luma(buffer))) }
            }
        }
        return values
    }
    func luma(_ sample:CMSampleBuffer)->Double {
        let pixel=CMSampleBufferGetImageBuffer(sample)!
        let image=CIImage(cvPixelBuffer:pixel).applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:CGRect(x:0,y:0,width:CVPixelBufferGetWidth(pixel),height:CVPixelBufferGetHeight(pixel)))])
        var data=[UInt8](repeating:0,count:4)
        CIContext().render(image,toBitmap:&data,rowBytes:4,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        return Double(data[0])
    }
    func details(_ info:ClipInfo)->MediaDetails {
        MediaDetails(duration:info.duration,origin:info.origin,width:Int(info.width),height:Int(info.height),rotation:info.rotation,pixelAspect:info.pixelAspect,fps:info.fps,hdr:info.hdr != 0,codec:"test",audioLabels:info.audioCount > 0 ? ["Audio"] : [],audioStreams:info.audioCount > 0 ? [1] : [])
    }
    func testAllInputFormatsDecodeAndSeekToContainingFrame() throws {
        for name in ["cfr.mp4","vfr.mkv","vp9.webm","av1.webm","legacy.avi","offset.mkv"] {
            let url=fixture(name)
            guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Run scripts/make-fixtures.sh first") }
            let all=try frames(url)
            XCTAssertGreaterThan(all.count,40,name)
            guard !all.isEmpty else { continue }
            let m=try open(url); defer { clip_close(m) }
            for target in [0.13,1.111,2.501,4.219,5.9] {
                let expected=all.last(where:{$0.0 <= target+0.000001}) ?? all[0]
                let sample=clip_frame(m,target)
                XCTAssertEqual(sample.kind,1,name)
                XCTAssertEqual(sample.time,expected.0,accuracy:0.000002,"\(name) at \(target)")
                if let unmanaged=sample.sample { unmanaged.release() }
            }
        }
    }
    func testHardwareExportsPreserveChosenFirstLastFramesAndVFR() async throws {
        for name in ["cfr.mp4","vfr.mkv","vp9.webm","offset.mkv"] {
            for codec in VideoCodec.allCases {
                let url=fixture(name)
                let all=try frames(url)
                let m=try open(url); let info=clip_info(m); clip_close(m)
                let chosen=Array(all.filter { $0.0 >= 1.2 && $0.0 < 2.8 })
                let next=all.first(where:{$0.0 > chosen.last!.0})!.0
                let output=fixture("output-\(name)-\(codec.rawValue).mp4")
                try? FileManager.default.removeItem(at:output)
                defer { try? FileManager.default.removeItem(at:output) }
                var edit=EditSettings(); edit.codec=codec; edit.quality=90
                let request=ExportRequest(source:url,details:details(info),edit:edit,start:chosen[0].0,end:next,destination:output)
                try await EncoderProcess().run(request) { _ in }
                let encoded=try frames(output)
                XCTAssertEqual(encoded.count,chosen.count,"\(name) \(codec)")
                guard encoded.count==chosen.count else { continue }
                for i in encoded.indices {
                    XCTAssertEqual(encoded[i].0,chosen[i].0-chosen[0].0,accuracy:0.002,"Timing \(name) frame \(i)")
                    XCTAssertEqual(encoded[i].1,chosen[i].1,accuracy:4,"Identity \(name) frame \(i)")
                }
            }
        }
    }
    func testHDRPreserveAndSDRConversion() async throws {
        let source=fixture("hdr.mp4")
        let m=try open(source); let info=clip_info(m); clip_close(m)
        XCTAssertEqual(info.hdr,1)
        for sdr in [false,true] {
            var edit=EditSettings(); edit.codec = sdr ? .h264 : .hevc; edit.convertToSDR=sdr
            let output=fixture(sdr ? "sdr-output.mp4" : "hdr-output.mp4")
            if FileManager.default.fileExists(atPath:output.path) { try FileManager.default.removeItem(at:output) }
            defer { if FileManager.default.fileExists(atPath:output.path) { try? FileManager.default.removeItem(at:output) } }
            try await EncoderProcess().run(ExportRequest(source:source,details:details(info),edit:edit,start:0,end:1,destination:output)) { _ in }
            let decoded=try open(output); defer { clip_close(decoded) }
            XCTAssertEqual(clip_info(decoded).hdr,sdr ? 0 : 1)
        }
    }
    func testCropNeverUpscalesAndPreservesRatio() {
        let info=MediaDetails(duration:10,origin:0,width:3840,height:2160,rotation:0,pixelAspect:1,fps:30,hdr:false,codec:"hevc",audioLabels:[],audioStreams:[])
        var edit=EditSettings(); edit.setCrop(ratio:9/16,size:info.displaySize); edit.resolution = .hd
        let g=edit.geometry(for:info)
        XCTAssertEqual(g.outHeight,1920); XCTAssertEqual(Double(g.outWidth)/Double(g.outHeight),9/16,accuracy:0.002)
        XCTAssertEqual(g.outHeight%2,0); XCTAssertEqual(g.outWidth%2,0)
        edit.crop=CGRect(x:0,y:0,width:0.02,height:0.02)
        let small=edit.geometry(for:info)
        XCTAssertLessThanOrEqual(small.outWidth,small.width); XCTAssertLessThanOrEqual(small.outHeight,small.height)
    }
    func testTimeParsingAndFormatting() {
        XCTAssertEqual(TimeText.parse("01:02:03.450"),3723.45)
        XCTAssertEqual(TimeText.parse("0.5"),0.5)
        XCTAssertNil(TimeText.parse("nan")); XCTAssertNil(TimeText.parse("-1"))
        XCTAssertEqual(TimeText.format(3723.45),"01:02:03.450")
    }
    func testRotationRead() throws {
        let m=try open(fixture("rotated.mp4")); defer { clip_close(m) }
        let info=clip_info(m)
        XCTAssertEqual(abs(info.rotation),90,accuracy:0.1)
        XCTAssertEqual(details(info).displaySize.width,90)
        XCTAssertEqual(details(info).displaySize.height,160)
    }
    func testCachedFrameSteppingUsesDecodedVFRBoundaries() throws {
        let url=fixture("vfr.mkv"), all=try frames(url)
        let m=try open(url); defer { clip_close(m) }; clip_enable_cache(m)
        var point=clip_frame(m,2.501)
        if let sample=point.sample { sample.release() }
        for _ in 0..<15 {
            let previous=point.time
            point=clip_frame(m,point.time+point.duration+0.000002)
            if let sample=point.sample { sample.release() }
            let expected=all.first(where:{$0.0 > previous+0.000001})!
            XCTAssertEqual(point.time,expected.0,accuracy:0.000002)
            let back=clip_frame(m,point.time-0.000002)
            if let sample=back.sample { sample.release() }
            XCTAssertEqual(back.time,previous,accuracy:0.000002)
        }
    }
    func testCachedBackwardStepsAfterVisitingTheLastFrame() throws {
        for cached in [false,true] {
            let m=try open(fixture("cfr.mp4")); defer { clip_close(m) }
            if cached { clip_enable_cache(m) }
            for t in [0,5.999999,0,1.0/24+0.000002,2.0/24+0.000002,143.0/24] {
                let s=clip_frame(m,t); if let sample=s.sample { sample.release() }
            }
            var t=143.0/24
            for _ in 0..<4 {
                let s=clip_frame(m,t-0.000002); if let sample=s.sample { sample.release() }
                XCTAssertEqual(s.time,t-1.0/24,accuracy:0.000003,"Cache enabled: \(cached)")
                t=s.time
            }
        }
    }
    func testCachedResumeMatchesContinuousAudioVideoDecode() throws {
        for name in ["cfr.mp4","vfr.mkv","vp9.webm","av1.webm"] {
            let expected=try frames(fixture(name))
            let m=try open(fixture(name)); defer { clip_close(m) }; clip_enable_cache(m)
            let point=clip_frame(m,2.501); point.sample?.release()
            XCTAssertEqual(clip_resume(m,point.time),1,"Resume cache should cover the selected frame and audio: \(name)")
            var actual:[Double]=[], audio:[(Double,Double)]=[]
            while true {
                let s=clip_next(m); s.sample?.release()
                if s.kind<=0 { XCTAssertEqual(s.kind,0); break }
                if s.kind==1 { actual.append(s.time) }
                else { audio.append((s.time,s.duration)) }
            }
            let chosen=expected.filter{$0.0>=point.time-0.000001}.map{$0.0}
            XCTAssertEqual(actual.count,chosen.count,name)
            for (a,b) in zip(actual,chosen) { XCTAssertEqual(a,b,accuracy:0.000002,name) }
            XCTAssertEqual(audio.first?.0 ?? -1,point.time,accuracy:1.0/48000+0.000001,name)
            for pair in zip(audio,audio.dropFirst()) { XCTAssertEqual(pair.0.0+pair.0.1,pair.1.0,accuracy:0.002,"Audio continuity: \(name)") }
        }
    }
    func testForwardContinuationKeepsCachedFrameIntervalsExact() throws {
        for name in ["cfr.mp4","vfr.mkv"] {
            let all=try frames(fixture(name)), m=try open(fixture(name)); defer { clip_close(m) }
            clip_enable_cache(m)
            for t in [1.001,2.99,1.083335,1.125002,1.166669] {
                let s=clip_frame(m,t); s.sample?.release()
                let expected=all.last(where:{$0.0<=t+0.000001})!.0
                XCTAssertEqual(s.time,expected,accuracy:0.000002,"\(name) at \(t)")
            }
        }
    }
    @MainActor func testReal4KPlaybackStartsAndResumesPromptlyWhenProvided() async throws {
        guard let path=ProcessInfo.processInfo.environment["CLIPPER_SAMPLE"] else { throw XCTSkip("Set CLIPPER_SAMPLE to measure transport latency") }
        let p=Playback(); let opened=expectation(description:"Sample opened")
        p.open(URL(fileURLWithPath:path),at:493.5,completion:{opened.fulfill()})
        await fulfillment(of:[opened],timeout:10)
        let start=Date(); p.play()
        try await waitUntil { p.clock.rate>0 }
        let first=Date().timeIntervalSince(start)
        XCTAssertLessThan(first,0.3,"Play after seeking should reuse decoded A/V")
        try await Task.sleep(nanoseconds:220_000_000)
        p.pauseAndResolve()
        XCTAssertFalse(p.seeking)
        XCTAssertEqual(p.frame?.time,p.position)
        let resume=Date(); p.play()
        try await waitUntil { p.clock.rate>0 }
        let elapsed=Date().timeIntervalSince(resume)
        XCTAssertLessThan(elapsed,0.08)
        print("Transport timing: initial \(Int(first*1000)) ms, warm resume \(Int(elapsed*1000)) ms")
        p.close()
    }
    @MainActor func testRapidStepsAndMarkWaitForTheRequestedFrame() async throws {
        let editor=Editor()
        editor.open(fixture("cfr.mp4"))
        for _ in 0..<250 where editor.loading || editor.playback.seeking { try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertFalse(editor.loading)
        editor.seek(2)
        editor.playback.step(1); editor.playback.step(1); editor.playback.step(1)
        editor.markStart()
        await withCheckedContinuation { continuation in editor.playback.afterPendingSeeks { continuation.resume() } }
        XCTAssertEqual(editor.start?.time ?? -1,2.125,accuracy:0.000002)
    }
    @MainActor func testSwitchingToOutputDoesNotStrandAnActiveSeek() async throws {
        let editor=Editor()
        editor.open(fixture("cfr.mp4"))
        for _ in 0..<250 where editor.loading || editor.playback.seeking { try await Task.sleep(nanoseconds:20_000_000) }
        editor.seek(2)
        editor.switchPreview(true)
        let settled=expectation(description:"The pending source seek finishes while output is visible")
        editor.playback.afterPendingSeeks { settled.fulfill() }
        await fulfillment(of:[settled],timeout:2)
        XCTAssertFalse(editor.playback.seeking)
        XCTAssertTrue(editor.canExport)
    }
    @MainActor private func waitUntil(_ condition:() -> Bool,timeout:Double=8,file:StaticString=#filePath,line:UInt=#line) async throws {
        let deadline=Date().addingTimeInterval(timeout)
        while !condition(), Date()<deadline { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertTrue(condition(),"Timed out waiting for media state",file:file,line:line)
    }
    @MainActor func testQuietComparisonChaseCoalescesAndCloseResetsState() async throws {
        let editor=Editor(); editor.open(fixture("vfr.mkv"))
        try await waitUntil { !editor.loading && !editor.playback.seeking }
        let settled=expectation(description:"The newest chase target is decoded")
        for n in 0..<30 {
            editor.playback.chase(1+Double(n)/30,completion:n==29 ? { settled.fulfill() } : nil)
            XCTAssertFalse(editor.playback.seeking)
            XCTAssertTrue(editor.canExport)
        }
        await fulfillment(of:[settled],timeout:4)
        XCTAssertLessThanOrEqual(editor.playback.frame?.time ?? 10,1+29.0/30+0.000002)
        editor.playback.chase(4.3)
        editor.close()
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertNil(editor.source); XCTAssertNil(editor.playback.details); XCTAssertNil(editor.playback.frame)
        XCTAssertEqual(editor.previewMode,.original); XCTAssertFalse(editor.previewReady); XCTAssertFalse(editor.playback.seeking)
    }
    @MainActor func testEncodedCompareStepsKeepSourceAndOutputFramesAligned() async throws {
        let editor=Editor(); editor.open(fixture("cfr.mp4"))
        try await waitUntil { !editor.loading && !editor.playback.seeking }
        editor.markStart(1)
        try await waitUntil { !editor.playback.seeking }
        editor.playback.seek(2.99)
        try await waitUntil { !editor.playback.seeking }
        editor.markEnd()
        try await waitUntil { !editor.playback.seeking }
        editor.seek(1)
        try await waitUntil { !editor.playback.seeking }
        editor.preview()
        try await waitUntil({ !editor.exporting && editor.previewReady },timeout:12)
        XCTAssertNotNil(editor.previewURL)
        editor.switchPreviewMode(.compare)
        try await waitUntil { !editor.comparisonPreparing }
        XCTAssertEqual(editor.previewMode,.compare)
        for _ in 0..<4 {
            let old=editor.previewPosition
            editor.stepFrame(1)
            try await waitUntil { !editor.comparisonPreparing && !editor.playback.seeking && editor.previewPosition>old+0.001 }
            XCTAssertEqual(editor.playback.frame?.time ?? -1,editor.previewStart+editor.previewPosition,accuracy:0.000003)
        }
        editor.stepFrame(-1)
        try await waitUntil { !editor.comparisonPreparing && !editor.playback.seeking }
        XCTAssertEqual(editor.playback.frame?.time ?? -1,editor.previewStart+editor.previewPosition,accuracy:0.000003)
        editor.stepFrame(1)
        editor.togglePlayback()
        try await waitUntil { editor.previewPlaying && editor.canExport }
        editor.togglePlayback()
        try await waitUntil { !editor.previewPlaying && !editor.comparisonPreparing }
        XCTAssertTrue(editor.canExport)
        let expectedStart=(editor.playback.frame?.time ?? 0)+1.0/24
        editor.stepFrame(1)
        editor.markStart()
        try await waitUntil { editor.previewMode == .original && !editor.playback.seeking }
        XCTAssertEqual(editor.start?.time ?? -1,expectedStart,accuracy:0.000003)
        XCTAssertEqual(editor.previewMode,.original); XCTAssertFalse(editor.previewReady); XCTAssertNil(editor.previewURL)
        editor.close()
    }
    @MainActor func testRapidBoundaryNudgesCommitEveryFrameAndRejectInvalidMarks() async throws {
        let editor=Editor(); editor.open(fixture("cfr.mp4"))
        try await waitUntil { !editor.loading && !editor.playback.seeking }
        let initialStart=editor.inTime, initialEnd=editor.end!.time
        editor.nudgeBoundary(start:true,direction:1); editor.nudgeBoundary(start:true,direction:1)
        try await waitUntil { editor.inTime>=initialStart+2.0/24-0.000001 && !editor.playback.seeking }
        XCTAssertEqual(editor.inTime,initialStart+2.0/24,accuracy:0.000003)
        editor.nudgeBoundary(start:false,direction:-1); editor.nudgeBoundary(start:false,direction:-1)
        try await waitUntil { (editor.end?.time ?? 10)<=initialEnd-2.0/24+0.000001 && !editor.playback.seeking }
        XCTAssertEqual(editor.end!.time,initialEnd-2.0/24,accuracy:0.000003)
        editor.markEnd(2.99)
        try await waitUntil { !editor.playback.seeking }
        let revision=editor.boundaryRevision, committed=editor.inTime
        editor.markStart(4)
        try await waitUntil { !editor.playback.seeking }
        XCTAssertEqual(editor.inTime,committed); XCTAssertNotNil(editor.error)
        XCTAssertGreaterThan(editor.boundaryRevision,revision,"A rejected timestamp still refreshes the field to its committed value")
        editor.close()
    }
    @MainActor func testCancelledPreviewRerenderKeepsTheCommittedRange() async throws {
        let editor=Editor(); editor.open(fixture("cfr.mp4"))
        try await waitUntil { !editor.loading && !editor.playback.seeking }
        editor.seek(1); try await waitUntil { !editor.playback.seeking }
        editor.preview(); try await waitUntil({ !editor.exporting && editor.previewReady },timeout:12)
        let url=editor.previewURL, start=editor.previewStart, duration=editor.previewDuration
        editor.seek(4); try await waitUntil { !editor.playback.seeking }
        editor.preview(); editor.cancel()
        try await waitUntil { !editor.exporting }
        XCTAssertEqual(editor.previewURL,url); XCTAssertEqual(editor.previewStart,start); XCTAssertEqual(editor.previewDuration,duration)
        XCTAssertTrue(editor.previewReady)
        editor.switchPreviewMode(.compare)
        try await waitUntil { !editor.comparisonPreparing }
        XCTAssertEqual(editor.playback.frame?.time ?? -1,editor.previewStart+editor.previewPosition,accuracy:0.000003)
        editor.close()
    }
    @MainActor func testComparisonSurfaceAlignsRoundedCropAndKeepsOneSourceOwner() {
        let source=AVSampleBufferDisplayLayer()
        let surface=ComparisonSurface.Surface(source:source,player:AVPlayer())
        surface.details=MediaDetails(duration:10,origin:0,width:3840,height:2160,rotation:0,pixelAspect:1,fps:60,hdr:false,codec:"av1",audioLabels:[],audioStreams:[])
        surface.edit.crop=CGRect(x:0.25,y:0.125,width:0.5,height:0.5)
        surface.mode = .compare; surface.wipe=0.4
        surface.frame=CGRect(x:0,y:0,width:960,height:540)
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(source.bounds.width,1920,accuracy:0.001)
        XCTAssertEqual(source.bounds.height,1080,accuracy:0.001)
        XCTAssertEqual(source.position.x,480,accuracy:0.001)
        XCTAssertEqual(source.position.y,135,accuracy:0.001)
        XCTAssertEqual(surface.wipeMask.frame.minX,384,accuracy:0.001)
        XCTAssertTrue(source.superlayer === surface.sourceViewport)
        for value in [0.1,0.9,0.2,0.8,0.5] {
            surface.moveDivider(to:value)
            XCTAssertEqual(surface.wipeMask.frame.minX,960*value,accuracy:0.001)
            XCTAssertEqual(surface.divider.frame.midX,960*value,accuracy:0.001)
            XCTAssertEqual(surface.knob.frame.midX,960*value,accuracy:0.001)
        }
        XCTAssertEqual(surface.layer?.sublayers?.filter{$0 === surface.divider}.count,1)
        XCTAssertNil(surface.divider.animationKeys())
        surface.mode = .output; surface.needsLayout=true; surface.layoutSubtreeIfNeeded()
        XCTAssertTrue(source.superlayer === surface.sourceViewport)
        XCTAssertTrue(surface.sourceViewport.isHidden)
        XCTAssertNil(surface.output.mask)
        surface.mode = .original; surface.needsLayout=true; surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(source.bounds.width,960,accuracy:0.001)
        XCTAssertEqual(source.bounds.height,540,accuracy:0.001)
        XCTAssertFalse(surface.sourceViewport.isHidden)
        ComparisonSurface.dismantleNSView(surface,coordinator:())
        XCTAssertNil(source.superlayer)
    }
    @MainActor func testReal4KQuietChaseKeepsUpWhenProvided() async throws {
        guard let path=ProcessInfo.processInfo.environment["CLIPPER_SAMPLE"] else { throw XCTSkip("Set CLIPPER_SAMPLE to measure comparison chasing") }
        let player=Playback()
        let opened=expectation(description:"The actual 4K source is primed")
        player.open(URL(fileURLWithPath:path),audioTrack:-1,at:493.5,completion:{ opened.fulfill() })
        await fulfillment(of:[opened],timeout:10)
        var updates=0
        let observation=player.$frame.dropFirst().sink { if $0 != nil { updates += 1 } }
        for n in 0..<45 {
            player.chase(493.5+Double(n)/30)
            XCTAssertFalse(player.seeking)
            try await Task.sleep(nanoseconds:33_333_333)
        }
        let settled=expectation(description:"The final comparison frame is delivered")
        player.chase(495,completion:{ settled.fulfill() })
        await fulfillment(of:[settled],timeout:3)
        XCTAssertGreaterThanOrEqual(updates,18,"The source should deliver at least 12 updates per second")
        observation.cancel(); player.close()
    }
    func testUserSampleCutWhenProvided() async throws {
        guard let path=ProcessInfo.processInfo.environment["CLIPPER_SAMPLE"] else { throw XCTSkip("Set CLIPPER_SAMPLE to test a real long-GOP 4K source") }
        let source=URL(fileURLWithPath:path)
        let m=try open(source); defer { clip_close(m) }; clip_enable_cache(m)
        let info=clip_info(m)
        let first=clip_frame(m,493.5), last=clip_frame(m,499.999999)
        if let sample=first.sample { sample.release() }; if let sample=last.sample { sample.release() }
        let output=fixture("real-sample-clip.mp4")
        if FileManager.default.fileExists(atPath:output.path) { try FileManager.default.removeItem(at:output) }
        var edit=EditSettings(); edit.codec = .h264
        try await EncoderProcess().run(ExportRequest(source:source,details:details(info),edit:edit,start:first.time,end:last.time+last.duration,destination:output)) { _ in }
        let result=try frames(output)
        XCTAssertEqual(result.count,391)
        XCTAssertEqual(result[0].0,0,accuracy:0.001)
        let rendered=try open(output); defer { clip_close(rendered) }
        XCTAssertEqual(clip_info(rendered).width,3840)
        XCTAssertEqual(clip_info(rendered).height,2160)
    }
}
