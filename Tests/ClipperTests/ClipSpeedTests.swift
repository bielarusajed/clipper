import AppKit
@preconcurrency import AVFoundation
import CMedia
import XCTest
@testable import Clipper

final class ClipSpeedTests:XCTestCase {
    private let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func fixture(_ name:String)->URL { root.appendingPathComponent(".build/fixtures/"+name) }
    @MainActor private func wait(_ condition:()->Bool,timeout:Double=15,file:StaticString=#filePath,line:UInt=#line) async throws {
        let deadline=Date().addingTimeInterval(timeout)
        while !condition(), Date()<deadline { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertTrue(condition(),"Timed out",file:file,line:line)
        if !condition() { throw ExportFailure.message("Timed out waiting for speed test operation") }
    }
    @MainActor private func opened(_ name:String="cfr.mp4") async throws -> Editor {
        _=NSApplication.shared
        let defaults=UserDefaults(suiteName:"Clipper.SpeedTests."+UUID().uuidString)!
        let editor=Editor(preferences:ExportPreferences(defaults:defaults))
        editor.open(fixture(name)); try await wait { !editor.loading && !editor.playback.seeking }
        return editor
    }

    func testHardwareExportsRetimeEveryCFRVFRAndOffsetFrameAndPreserveAudioPitch() async throws {
        for name in ["cfr.mp4","vfr.mkv","offset.mkv"] {
            let source=fixture(name), media=MediaTests()
            let all=try media.frames(source), decoder=try media.open(source)
            let details=media.details(clip_info(decoder)); clip_close(decoder)
            let chosen=all.filter { $0.0>=1 && $0.0<3 }
            let start=try XCTUnwrap(chosen.first).0
            let end=try XCTUnwrap(all.first { $0.0>chosen.last!.0 }).0
            for speed in [ClipSpeed.quarter,.threeQuarters,.oneAndHalf,.quadruple] {
                for codec in VideoCodec.allCases {
                    var edit=EditSettings(); edit.speed=speed; edit.codec=codec; edit.quality=90
                    let output=fixture("speed-\(UUID().uuidString).mp4")
                    defer { try? FileManager.default.removeItem(at:output) }
                    let request=ExportRequest(source:source,details:details,edit:edit,start:start,end:end,destination:output)
                    try await EncoderProcess().run(request) { _ in }
                    let encoded=try media.frames(output)
                    XCTAssertEqual(encoded.count,chosen.count,"\(name), \(speed), \(codec)")
                    guard encoded.count==chosen.count else { continue }
                    for i in encoded.indices {
                        XCTAssertEqual(encoded[i].0,speed.outputTime(chosen[i].0-start),accuracy:0.0001,"\(name), \(speed), frame \(i)")
                        XCTAssertEqual(encoded[i].1,chosen[i].1,accuracy:4)
                    }
                    let result=try media.open(output); defer { clip_close(result) }
                    XCTAssertEqual(clip_info(result).duration,request.outputDuration,accuracy:0.12)
                    var firstAudio:Double?, audioEnd=0.0, samples=[Float]()
                    while true {
                        let next=clip_next(result)
                        if next.kind==0 { break }
                        XCTAssertGreaterThan(next.kind,0); if next.kind<0 { break }
                        guard let buffer=next.sample?.takeRetainedValue(), next.kind==2 else { continue }
                        firstAudio=firstAudio ?? next.time; audioEnd=next.time+next.duration
                        if let block=CMSampleBufferGetDataBuffer(buffer) {
                            let count=CMBlockBufferGetDataLength(block)/MemoryLayout<Float>.size
                            var pcm=[Float](repeating:0,count:count)
                            let status=pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!) }
                            XCTAssertEqual(status,noErr)
                            samples += stride(from:0,to:pcm.count,by:2).map { pcm[$0] }
                        }
                    }
                    XCTAssertEqual(try XCTUnwrap(firstAudio),0,accuracy:0.03)
                    XCTAssertEqual(audioEnd,request.outputDuration,accuracy:0.12)
                    // Measure the fixture's 440 Hz tone away from encoder/tempo edges.
                    let interior=Array(samples.dropFirst(2400).dropLast(2400))
                    XCTAssertGreaterThan(interior.count,4800)
                    let crossings=zip(interior,interior.dropFirst()).filter { $0<=0 && $1>0 }.count
                    XCTAssertEqual(Double(crossings)*48000/Double(interior.count),440,accuracy:8)
                }
            }
        }
    }

    @MainActor func testLiveSpeedLoopWarmResumeUndoAndSourceReset() async throws {
        let editor=try await opened(); defer { editor.close() }
        editor.markStart(1); try await wait { !editor.playback.seeking }
        editor.markEnd(1.49); try await wait { !editor.playback.seeking }
        editor.seek(editor.inTime); try await wait { !editor.playback.seeking }
        let selection=editor.snapshot
        editor.toggleLoop(); editor.togglePlayback()
        try await wait { editor.playback.clock.rate>0 }
        for speed in [ClipSpeed.half,.quadruple] {
            editor.updateSettings("Speed") { $0.speed=speed }
            XCTAssertEqual(editor.playback.clock.rate,Float(speed.rawValue))
            XCTAssertTrue(editor.isPlaying)
            try await Task.sleep(nanoseconds:200_000_000)
            XCTAssertEqual(editor.start,selection.start); XCTAssertEqual(editor.end,selection.end)
            XCTAssertEqual(editor.outputDuration,editor.clipDuration/speed.rawValue)
            editor.togglePlayback(); editor.togglePlayback()
            try await wait { editor.playback.clock.rate==Float(speed.rawValue) }
        }
        editor.undoEdit(); try await wait { !editor.playback.seeking }
        XCTAssertEqual(editor.edit.speed,.half); XCTAssertEqual(editor.playback.speed,.half)
        XCTAssertFalse(editor.isPlaying)
        editor.redoEdit(); try await wait { !editor.playback.seeking }
        XCTAssertEqual(editor.edit.speed,.quadruple); XCTAssertEqual(editor.playback.speed,.quadruple)
        editor.open(fixture("vfr.mkv")); try await wait { !editor.loading && !editor.playback.seeking }
        XCTAssertEqual(editor.edit.speed,.normal); XCTAssertEqual(editor.playback.speed,.normal)
    }

    func testSingleFrameSpeedExportScalesItsFinalDurationWithoutAudio() async throws {
        let media=MediaTests(), source=fixture("cfr.mp4"), decoder=try media.open(source)
        let details=media.details(clip_info(decoder)); clip_close(decoder)
        for speed in [ClipSpeed.quarter,.quadruple] {
            var edit=EditSettings(); edit.speed=speed; edit.muted=true
            let output=fixture("speed-single-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at:output) }
            let request=ExportRequest(source:source,details:details,edit:edit,start:1,end:1+1.0/24,destination:output)
            try await EncoderProcess().run(request) { _ in }
            XCTAssertEqual(try media.frames(output).count,1)
            let result=try media.open(output); defer { clip_close(result) }
            XCTAssertEqual(clip_info(result).audioCount,0)
            let frame=clip_frame(result,0); frame.sample?.release()
            XCTAssertEqual(frame.duration,request.outputDuration,accuracy:0.00001)
        }
    }

    @MainActor func testSpeedExportBurnsSubtitlesAtRetimedCueBoundaries() async throws {
        let subtitles=SubtitleTests()
        let controller=try await subtitles.controller("dialogue.srt")
        let details=try subtitles.details(), asset=try XCTUnwrap(controller.render)
        for speed in [ClipSpeed.half,.double] {
            var edit=EditSettings(); edit.speed=speed; edit.muted=true
            let output=fixture("speed-subtitles-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at:output) }
            try await EncoderProcess().run(ExportRequest(source:subtitles.fixture("black.mp4"),details:details,edit:edit,start:1,end:5,destination:output,subtitles:asset)) { _ in }
            let before=try subtitles.luminance(output,time:speed.outputTime(0.5))
            let during=try subtitles.luminance(output,time:speed.outputTime(1.5))
            let after=try subtitles.luminance(output,time:speed.outputTime(3.5))
            XCTAssertLessThan(before.max() ?? 255,30)
            XCTAssertGreaterThan(during.max() ?? 0,180)
            XCTAssertLessThan(after.max() ?? 255,30)
        }
    }

    @MainActor func testSpeedPreviewCompareStepsMarkersModeSwitchAndInvalidation() async throws {
        for speed in [ClipSpeed.half,.quadruple] {
            let editor=try await opened(); defer { editor.close() }
            editor.markStart(1); try await wait { !editor.playback.seeking }
            editor.markEnd(4.99); try await wait { !editor.playback.seeking }
            editor.seek(editor.inTime); try await wait { !editor.playback.seeking }
            editor.updateSettings("Speed") { $0.speed=speed }
            editor.preview(); try await wait { !editor.exporting && editor.previewReady }
            XCTAssertNil(editor.error)
            XCTAssertEqual(editor.previewDuration,min(speed.sourceTime(5),editor.clipDuration),accuracy:0.00001)
            editor.switchPreviewMode(.compare); try await wait { !editor.comparisonPreparing }
            for direction in [1,1,1,-1] {
                editor.stepFrame(direction)
                try await wait { !editor.comparisonPreparing && !editor.playback.seeking }
                XCTAssertEqual(editor.playback.frame?.time ?? -1,editor.displayedPosition,accuracy:0.00001)
            }
            let position=editor.displayedPosition
            editor.switchPreviewMode(.original); try await wait { !editor.playback.seeking }
            XCTAssertEqual(editor.playback.position,position,accuracy:0.00001)
            editor.switchPreviewMode(.output); try await wait { !editor.comparisonPreparing }
            editor.togglePlayback(); try await wait { editor.previewPlaying }
            XCTAssertEqual(editor.outputPlayer.rate,1,"Encoded samples already contain the speed change")
            editor.togglePlayback(); try await wait { !editor.comparisonPreparing }
            editor.stepFrame(1); editor.markStart()
            try await wait { editor.previewMode == .original && !editor.playback.seeking }
            XCTAssertGreaterThan(editor.inTime,position)
            XCTAssertNil(editor.previewURL)
            editor.seek(editor.inTime); try await wait { !editor.playback.seeking }
            editor.preview(); try await wait { !editor.exporting && editor.previewReady }
            editor.updateSettings("Speed") { $0.speed = .normal }
            XCTAssertFalse(editor.previewReady); XCTAssertNil(editor.previewURL)
            XCTAssertEqual(editor.previewMode,.original); XCTAssertFalse(editor.isPlaying)
        }
    }

    @MainActor func testAuditionAtSpeedHoldsSelectedLastFrame() async throws {
        for speed in [ClipSpeed.half,.quadruple] {
            let editor=try await opened(); defer { editor.close() }
            editor.markStart(1); try await wait { !editor.playback.seeking }
            editor.markEnd(2.99); try await wait { !editor.playback.seeking }
            editor.updateSettings("Speed") { $0.speed=speed }
            for mode in [PreviewMode.original,.output,.compare] {
                if mode == .output {
                    editor.seek(editor.inTime); try await wait { !editor.playback.seeking }
                    editor.preview(); try await wait { !editor.exporting && editor.previewReady }
                }
                editor.switchPreviewMode(mode); try await wait { !editor.comparisonPreparing }
                editor.auditionCut()
                try await wait { !editor.auditioning && !editor.playback.seeking && !editor.comparisonPreparing }
                XCTAssertEqual(editor.previewMode,mode)
                XCTAssertFalse(editor.isPlaying)
                if mode != .output { XCTAssertEqual(editor.playback.frame?.pts,editor.end?.pts) }
            }
        }
    }
}
