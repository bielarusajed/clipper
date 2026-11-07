import XCTest
import CMedia
import AppKit
import SwiftUI
@testable import Clipper

final class WaveformTests:XCTestCase {
    private let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func fixture(_ name:String) throws -> URL {
        let url=root.appendingPathComponent(".build/fixtures/"+name)
        guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Run scripts/make-waveform-fixtures.sh") }
        return url
    }
    private func info(_ url:URL) throws -> ClipInfo {
        var error=[CChar](repeating:0,count:256)
        let pointer=clip_open(url.path,0,&error,256)
        let media=try XCTUnwrap(pointer)
        defer { clip_close(media) }; return clip_info(media)
    }
    private func peaks(_ name:String,stream:Int,origin:Double,duration:Double) throws -> WaveformPeaks {
        try WaveformJob().generate(url:fixture(name),stream:stream,origin:origin,duration:duration) { _ in }
    }
    private func onset(_ peaks:WaveformPeaks,near time:Double,threshold:Float=0.25) throws -> Double {
        let first=max(0,Int((time-0.1)/peaks.binWidth)), last=min(peaks.levels[0].count-1,Int((time+0.1)/peaks.binWidth))
        let index=try XCTUnwrap((first...last).first(where:{peaks.levels[0][$0]>threshold}))
        return Double(index)*peaks.binWidth
    }
    func testDecodedPeaksFollowPlaybackOriginOffsetsVFRAndSelectedTrack() throws {
        let url=try fixture("waveform-offset.mkv"), details=try info(url)
        XCTAssertEqual(details.origin,7,accuracy:0.001); XCTAssertEqual(details.audioCount,2)
        let a=try peaks("waveform-offset.mkv",stream:1,origin:details.origin,duration:5)
        let b=try peaks("waveform-offset.mkv",stream:2,origin:details.origin,duration:5)
        XCTAssertEqual(try onset(a,near:1.35),1.35,accuracy:0.005001)
        XCTAssertEqual(try onset(a,near:3.35),3.35,accuracy:0.005)
        XCTAssertEqual(try onset(b,near:2.1),2.1,accuracy:0.005)
        XCTAssertEqual(a.peak(from:2.0,to:2.2),0)
        XCTAssertEqual(b.peak(from:1.2,to:1.5),0)
        XCTAssertEqual(a.peak(from:1.35,to:1.37),0.8,accuracy:0.001,"Opposite-polarity stereo must not cancel")
        // Deep zoom and fit use the same time coordinates and preserve short peaks.
        for width in [500.0,8_000_000] {
            let x=1.35/5*width
            XCTAssertGreaterThan(a.peak(from:x/width*5,to:(x+1)/width*5),0.7)
        }
    }
    func testAACAndOpusPrimingUseDecodedFrameTimestamps() throws {
        for name in ["waveform-aac.mp4","waveform-opus.mkv"] {
            let details=try info(fixture(name))
            let result=try peaks(name,stream:1,origin:details.origin,duration:2)
            let measured=try onset(result,near:0.5)
            print("Waveform timing \(name): burst at 0.500 s, onset \(measured) s")
            XCTAssertEqual(measured,0.5,accuracy:0.025,name)
            XCTAssertEqual(result.peak(from:0.1,to:0.3),0,accuracy:0.001)
        }
    }
    func testLongSparseSourceAndModerateDecodeHaveBoundedStorage() throws {
        let long=try peaks("waveform-long.mka",stream:0,origin:0,duration:100000.2)
        XCTAssertEqual(long.levels[0].count,WaveformPeaks.maximumBins)
        XCTAssertLessThan(long.byteCount,8_000_100)
        XCTAssertGreaterThan(long.peak(from:0,to:0.1),0.6)
        XCTAssertGreaterThan(long.peak(from:100000.1,to:100000.2),0.6)
        XCTAssertEqual(long.peak(from:40000,to:60000),0)
        let moderate=try peaks("waveform-moderate.mka",stream:0,origin:0,duration:180)
        XCTAssertEqual(moderate.levels[0].count,36000)
        for t in [30.0,60,90,120,150] {
            XCTAssertGreaterThan(moderate.peak(from:t,to:t+0.01),0.4)
            XCTAssertEqual(moderate.peak(from:t+1,to:t+2),0)
        }
    }
    func testReaderCancellationBeforeOpenAndBetweenBatches() throws {
        let request=try XCTUnwrap(clip_request_create()); defer { clip_request_free(request) }
        var error=[CChar](repeating:0,count:256)
        clip_request_set(request,1)
        let url=try fixture("waveform-moderate.mka")
        XCTAssertNil(clip_waveform_open(url.path,0,0,request,0,&error,256))
        clip_request_set(request,0)
        let reader=try XCTUnwrap(clip_waveform_open(url.path,0,0,request,0,&error,256))
        defer { clip_waveform_close(reader) }
        var values=[Float](repeating:0,count:36000), position=0.0
        XCTAssertEqual(clip_waveform_step(reader,&values,36000,0.005,&position,&error,256),1)
        clip_request_set(request,1)
        XCTAssertLessThan(clip_waveform_step(reader,&values,36000,0.005,&position,&error,256),0)
    }
    func testRoundedFinalBinDoesNotWritePastBufferOrTrapDuringDrawing() throws {
        // This sample is below count*width, yet rounds to bin 37 on division.
        let width=1.0135135135135136e-05, count=37, time=3.0/8000
        XCTAssertLessThan(time,Double(count)*width)
        XCTAssertEqual(floor(time/width),Double(count))
        let request=try XCTUnwrap(clip_request_create()); defer { clip_request_free(request) }
        var error=[CChar](repeating:0,count:256)
        let reader=try XCTUnwrap(clip_waveform_open(try fixture("waveform-moderate.mka").path,0,0,request,0,&error,256))
        defer { clip_waveform_close(reader) }
        var values=[Float](repeating:0,count:count+1), position=0.0
        values[count] = -123
        while clip_waveform_step(reader,&values,Int32(count),width,&position,&error,256)>0 {}
        XCTAssertEqual(values[count],-123,"The buffer sentinel must remain untouched")
        let result=WaveformPeaks(duration:Double(count)*width,peaks:Array(values.prefix(count)))
        XCTAssertGreaterThan(result.peak(from:result.duration.nextDown,to:result.duration),0.4)
    }
    func testCancelWhileReaderIsOpenAndPaused() async throws {
        let work=WaveformJob(), progressed=expectation(description:"Reader produced a batch")
        let url=try fixture("waveform-moderate.mka")
        let task=Task.detached { () -> Bool in
            do {
                _=try work.generate(url:url,stream:0,origin:0,duration:180) { _ in
                    work.setPaused(true); progressed.fulfill()
                }
                return false
            } catch { return true }
        }
        await fulfillment(of:[progressed],timeout:5)
        work.cancel()
        let cancelled=await task.value
        XCTAssertTrue(cancelled)
    }
    @MainActor private func waitUntil(_ condition:()->Bool) async throws {
        let end=Date().addingTimeInterval(10)
        while !condition() {
            if Date()>end { XCTFail("Timed out"); return }
            try await Task.sleep(nanoseconds:10_000_000)
        }
    }
    @MainActor func testPauseTrackChangesCacheAndSourceInvalidation() async throws {
        let waveform=AudioWaveform(), url=try fixture("waveform-offset.mkv")
        func update(_ stream:Int,busy:Bool=false,enabled:Bool=true) {
            waveform.update(url:url,stream:stream,origin:7,duration:5,enabled:enabled,busy:busy,lease:nil)
        }
        update(1,busy:true)
        try await Task.sleep(nanoseconds:400_000_000)
        XCTAssertTrue(waveform.generating); XCTAssertEqual(waveform.progress,0); XCTAssertNil(waveform.peaks)
        update(2) // Cancel the paused first track and never publish its result.
        try await waitUntil { !waveform.generating }
        XCTAssertNil(waveform.failure)
        XCTAssertEqual(try onset(XCTUnwrap(waveform.peaks),near:2.1),2.1,accuracy:0.005)
        update(1)
        try await waitUntil { !waveform.generating }
        XCTAssertEqual(waveform.cachedTrackCount,2)
        update(2)
        XCTAssertFalse(waveform.generating,"The completed track should be cached")
        update(2,enabled:false); XCTAssertNil(waveform.peaks)
        update(2); XCTAssertNotNil(waveform.peaks); XCTAssertFalse(waveform.generating)
        waveform.resetSource(); XCTAssertEqual(waveform.cachedTrackCount,0); XCTAssertNil(waveform.peaks)
        update(1,busy:true); waveform.resetSource()
        try await Task.sleep(nanoseconds:350_000_000)
        XCTAssertFalse(waveform.generating); XCTAssertNil(waveform.peaks)
        waveform.cancelAndWait()
    }
    @MainActor func testEditorTrackChangesZoomAndClose() async throws {
        _=NSApplication.shared
        let editor=Editor(); editor.waveformVisible=true
        editor.open(try fixture("waveform-offset.mkv"))
        defer { editor.close(); editor.waveform.cancelAndWait() }
        try await waitUntil { !editor.loading && !editor.playback.seeking && editor.waveform.peaks != nil }
        let duration=try XCTUnwrap(editor.details).duration
        XCTAssertLessThan(duration,5.1,"Use the editor's corrected video duration")
        XCTAssertEqual(try onset(XCTUnwrap(editor.waveform.peaks),near:1.35),1.35,accuracy:0.005)
        editor.timelineZoom=8
        editor.updateSettings("Audio Track") { $0.audioTrack=1 }
        try await waitUntil { !editor.playback.seeking && editor.waveform.peaks != nil }
        XCTAssertEqual(try onset(XCTUnwrap(editor.waveform.peaks),near:2.1),2.1,accuracy:0.005)
        editor.close(); XCTAssertNil(editor.waveform.peaks)
        editor.open(try fixture("waveform-silent.mkv"))
        try await waitUntil { !editor.loading && !editor.playback.seeking }
        XCTAssertEqual(editor.details?.audioLabels.count,0)
        XCTAssertNil(editor.waveform.peaks); XCTAssertFalse(editor.waveform.generating)
    }
    @MainActor func testCancelledJobReleasesManagedSourceAfterClosingReader() throws {
        let directory=root.appendingPathComponent(".build/waveform-lease-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url=directory.appendingPathComponent("source.mkv")
        try FileManager.default.copyItem(at:fixture("waveform-offset.mkv"),to:url)
        var lease:TemporaryImport?=TemporaryImport(directory:directory,file:url)
        let waveform=AudioWaveform()
        waveform.update(url:url,stream:1,origin:7,duration:5,enabled:true,busy:true,lease:lease)
        lease=nil
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
        waveform.cancelAndWait()
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
    }
    @MainActor func testWaveformTimelineFitsAndRendersAtFitAndDeepZoom() async throws {
        _=NSApplication.shared
        let editor=Editor(); editor.waveformVisible=true
        editor.open(try fixture("waveform-offset.mkv"))
        let host=NSHostingView(rootView:Timeline(editor:editor,playback:editor.playback).background(Color(nsColor:.windowBackgroundColor)))
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:850,height:EditorWindowLayout.timelineHeight),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.contentView=host
        defer { window.contentView=nil; window.close(); editor.close(); editor.waveform.cancelAndWait() }
        try await waitUntil { !editor.loading && !editor.playback.seeking && editor.waveform.peaks != nil }
        func descendant(_ view:NSView)->TimelineScrollView? {
            if let scroll=view as? TimelineScrollView { return scroll }
            return view.subviews.lazy.compactMap { descendant($0) }.first
        }
        for (index,zoom) in [0.0,5.0,0.0].enumerated() {
            if index==1 {
                editor.seek(1.35)
                try await waitUntil { !editor.playback.seeking }
            }
            editor.timelineZoom=zoom
            try await Task.sleep(nanoseconds:300_000_000)
            host.layoutSubtreeIfNeeded()
            let scroll=try XCTUnwrap(descendant(host)), canvas=try XCTUnwrap(scroll.documentView as? TimelineCanvas)
            XCTAssertTrue(canvas.waveformVisible); XCTAssertNotNil(canvas.waveform)
            XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.height,canvas.frame.height)
            XCTAssertEqual(canvas.frame.height,84); XCTAssertEqual(scroll.contentView.bounds.minY,0)
            if index<2 {
                let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
                host.cacheDisplay(in:host.bounds,to:bitmap)
                // NSView.clear leaves transparent pixels in offscreen captures.
                // Render over the native window colour for a reviewable screenshot.
                let image=NSImage(size:host.bounds.size,flipped:false) { rect in
                    NSColor.windowBackgroundColor.setFill(); rect.fill()
                    NSImage(cgImage:bitmap.cgImage!,size:host.bounds.size).draw(in:rect,from:.zero,operation:.sourceOver,fraction:1)
                    return true
                }
                let opaque=try XCTUnwrap(NSBitmapImageRep(data:XCTUnwrap(image.tiffRepresentation)))
                try XCTUnwrap(opaque.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent(".build/waveform-timeline-\(index).png"))
            }
        }
        editor.waveformVisible=false
        try await Task.sleep(nanoseconds:100_000_000)
        host.layoutSubtreeIfNeeded()
        let scroll=try XCTUnwrap(descendant(host)), canvas=try XCTUnwrap(scroll.documentView as? TimelineCanvas)
        XCTAssertFalse(canvas.waveformVisible)
        XCTAssertEqual(canvas.frame.height,84)
    }
}
