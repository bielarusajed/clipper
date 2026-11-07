import AppKit
@preconcurrency import AVFoundation
import Combine
import XCTest
@testable import Clipper

final class LoopAuditionTests:XCTestCase {
    private func fixture(_ name:String)->URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/fixtures/"+name)
    }
    @MainActor private func wait(_ condition:() -> Bool,timeout:Double=8,file:StaticString=#filePath,line:UInt=#line) async throws {
        let deadline=Date().addingTimeInterval(timeout)
        while !condition(), Date()<deadline { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertTrue(condition(),"Timed out waiting for transport",file:file,line:line)
    }
    @MainActor private func open(_ name:String="cfr.mp4")->Editor {
        _=NSApplication.shared
        let editor=Editor(); editor.open(fixture(name)); return editor
    }
    @MainActor private func select(_ editor:Editor,start:Double,end:Double) async throws {
        try await wait { !editor.loading && !editor.playback.seeking }
        editor.markStart(start); try await wait { !editor.playback.seeking }
        editor.markEnd(end); try await wait { !editor.playback.seeking }
        editor.seek(editor.inTime); try await wait { !editor.playback.seeking }
    }
    // Legacy display-layer enqueue is used on the serial decode queue, as in Playback.
    // @preconcurrency and the nonisolated override retain that SDK contract for this observer.
    private final class VideoSamples:AVSampleBufferDisplayLayer {
        private let lock=NSLock()
        nonisolated(unsafe) private var times:[Double]=[]
        var imageRemovals=0
        var timestamps:[Double] { lock.withLock { times } }
        nonisolated override func enqueue(_ buffer:CMSampleBuffer) {
            lock.withLock { times.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds) }
            super.enqueue(buffer)
        }
        override func flushAndRemoveImage() { imageRemovals += 1; super.flushAndRemoveImage() }
    }
    private final class AudioSamples:AVSampleBufferAudioRenderer {
        private let lock=NSLock()
        nonisolated(unsafe) private var ends:[Double]=[]
        var endTimes:[Double] { lock.withLock { ends } }
        nonisolated override func enqueue(_ buffer:CMSampleBuffer) {
            lock.withLock { ends.append((CMSampleBufferGetPresentationTimeStamp(buffer)+CMSampleBufferGetDuration(buffer)).seconds) }
            super.enqueue(buffer)
        }
    }
    @MainActor func testDecoderEnforcesExclusiveCutForVideoAndAudioAndRetainsImage() async throws {
        let video=VideoSamples(), audio=AudioSamples(), player=Playback(video:video,audio:audio)
        defer { player.close() }
        var opened=false
        player.open(fixture("cfr.mp4"),at:1,completion:{ opened=true })
        try await wait { opened }
        let removals=video.imageRemovals
        let end=1+3.0/24
        var passes=0, finished=false, lastFrameCount=0
        player.playRange(until:end,loopStart:1,shouldLoop:{
            let count=video.timestamps.filter { abs($0-(end-1.0/24))<0.000001 }.count
            XCTAssertGreaterThan(count,lastFrameCount,"The last included B-frame must be enqueued in every pass")
            lastFrameCount=count; passes += 1; return passes<3
        },onEnd:{ finished=true })
        try await wait { finished }
        XCTAssertEqual(passes,3)
        XCTAssertFalse(video.timestamps.isEmpty); XCTAssertFalse(audio.endTimes.isEmpty)
        XCTAssertTrue(video.timestamps.allSatisfy { $0<end-0.0000001 })
        XCTAssertTrue(audio.endTimes.allSatisfy { $0<=end+0.000001 },"No audio sample may cross the cut")
        XCTAssertGreaterThan(audio.endTimes.max() ?? 0,end-1.0/48000-0.000001)
        XCTAssertEqual(video.imageRemovals,removals,"Wraps must keep the image visible")
        XCTAssertFalse(player.transportWanted)
    }
    @MainActor func testShortAndVFRSelectionsLoopWithoutChangingMarkers() async throws {
        for name in ["cfr.mp4","vfr.mkv"] {
            let editor=open(name); defer { editor.close() }
            try await select(editor,start:1,end:1.12)
            let start=editor.start, end=editor.end
            var passes=0
            let observation=editor.playback.$seeking.dropFirst().sink { if $0 { passes += 1 } }
            editor.toggleLoop()
            XCTAssertFalse(editor.isPlaying,"Enabling loop while paused starts nothing")
            editor.togglePlayback()
            try await wait { passes>=3 && editor.playback.clock.rate>0 }
            XCTAssertTrue(editor.isPlaying,"Playback stays requested through wraps")
            XCTAssertEqual(editor.start,start); XCTAssertEqual(editor.end,end)
            XCTAssertLessThan(editor.playback.frame?.time ?? 100,editor.outTime)
            editor.togglePlayback()
            try await Task.sleep(nanoseconds:200_000_000)
            XCTAssertFalse(editor.isPlaying); XCTAssertFalse(editor.playback.playing)
            XCTAssertEqual(editor.playback.clock.rate,0)
            observation.cancel()
        }
    }
    @MainActor func testAuditionOverridesLoopAndHoldsExactLastFrame() async throws {
        for name in ["cfr.mp4","vfr.mkv"] {
            let editor=open(name); defer { editor.close() }
            try await select(editor,start:1,end:2.99)
            let start=editor.start, end=editor.end
            editor.toggleLoop(); editor.auditionCut()
            try await wait { editor.playback.clock.rate>0 }
            XCTAssertLessThanOrEqual(editor.playback.position,editor.outTime-1+0.04)
            try await wait { !editor.auditioning && !editor.playback.seeking }
            XCTAssertFalse(editor.isPlaying); XCTAssertTrue(editor.loopEnabled)
            XCTAssertEqual(editor.start,start); XCTAssertEqual(editor.end,end)
            XCTAssertEqual(editor.playback.frame?.pts,end?.pts)
            XCTAssertEqual(editor.playback.clock.rate,0)
            // Space from the last included frame restarts at the in point.
            editor.togglePlayback(); try await wait { editor.playback.clock.rate>0 }
            XCTAssertLessThan(editor.playback.position,editor.inTime+0.2)
        }
    }
    @MainActor func testSingleFrameAuditionPrimesAndRapidCancellationCannotRestart() async throws {
        let editor=open(); defer { editor.close() }
        try await select(editor,start:1,end:1)
        editor.auditionCut()
        try await wait { !editor.auditioning && !editor.playback.seeking }
        XCTAssertEqual(editor.playback.frame?.pts,editor.end?.pts)
        for _ in 0..<12 {
            editor.auditionCut(); editor.togglePlayback()
        }
        try await Task.sleep(nanoseconds:250_000_000)
        XCTAssertFalse(editor.isPlaying); XCTAssertFalse(editor.auditioning)
        XCTAssertEqual(editor.playback.clock.rate,0)
        // A completed single-frame audition must be replayable with Space.
        editor.auditionCut()
        try await wait { !editor.auditioning && !editor.playback.seeking }
        editor.togglePlayback()
        try await wait { !editor.isPlaying && !editor.playback.seeking }
        editor.auditionCut(); editor.close()
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertNil(editor.source); XCTAssertNil(editor.playback.frame)
        XCTAssertFalse(editor.loopEnabled); XCTAssertFalse(editor.isPlaying)
    }
    @MainActor func testSingleFrameSelectionLoopsAndSettingsKeepOriginalPlaying() async throws {
        let editor=open(); defer { editor.close() }
        try await select(editor,start:1,end:1)
        var wraps=0
        let observation=editor.playback.$seeking.dropFirst().sink { if $0 { wraps += 1 } }
        editor.toggleLoop(); editor.togglePlayback()
        try await wait { wraps>=3 && editor.playback.clock.rate>0 }
        let old=editor.edit
        editor.edit.muted.toggle(); editor.settingsChanged(old)
        XCTAssertTrue(editor.isPlaying,"Changing mute/crop/codec keeps Original transport running")
        try await wait { wraps>=5 && editor.playback.clock.rate>0 }
        editor.togglePlayback()
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertFalse(editor.isPlaying)
        observation.cancel()
    }
    @MainActor func testPauseDuringWrapAndSourceReplacementInvalidateRestarts() async throws {
        let editor=open(); defer { editor.close() }
        try await select(editor,start:1,end:1.04)
        editor.toggleLoop(); editor.togglePlayback()
        try await wait { editor.playback.seeking }
        editor.playback.pause()
        try await Task.sleep(nanoseconds:200_000_000)
        XCTAssertFalse(editor.isPlaying); XCTAssertFalse(editor.playback.playing)
        editor.togglePlayback()
        editor.open(fixture("vfr.mkv"))
        try await wait { !editor.loading && !editor.playback.seeking }
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertFalse(editor.loopEnabled); XCTAssertFalse(editor.isPlaying)
        XCTAssertEqual(editor.source,fixture("vfr.mkv"))
    }
    @MainActor func testLoopToggleDuringPlayAndEditingInterruptsTransport() async throws {
        let editor=open(); defer { editor.close() }
        try await select(editor,start:1,end:1.2)
        editor.togglePlayback()
        for _ in 0..<11 { editor.toggleLoop() }
        try await wait { editor.playback.seeking }
        XCTAssertTrue(editor.isPlaying)
        editor.toggleLoop() // Finish the current pass.
        try await wait { !editor.isPlaying && !editor.playback.seeking }
        XCTAssertEqual(editor.playback.frame?.pts,editor.end?.pts)
        editor.toggleLoop(); editor.togglePlayback()
        editor.markEnd(1.4)
        try await wait { !editor.playback.seeking }
        XCTAssertFalse(editor.isPlaying)
        editor.auditionCut(); editor.showURLImporter()
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertFalse(editor.isPlaying); XCTAssertFalse(editor.auditioning)
        editor.importPresented=false
    }
    @MainActor func testEncodedLoopAndAuditionInOutputAndCompare() async throws {
        for name in ["cfr.mp4","vfr.mkv"] {
            let editor=open(name); defer { editor.close() }
            try await select(editor,start:1,end:1.49)
            let start=editor.start, end=editor.end
            editor.preview(); try await wait({ !editor.exporting && editor.previewReady },timeout:20)
            XCTAssertNil(editor.error)
            for mode in [PreviewMode.output,.compare] {
                editor.switchPreviewMode(mode)
                try await wait { !editor.comparisonPreparing }
                if !editor.loopEnabled { editor.toggleLoop() }
                editor.togglePlayback()
                try await wait { editor.previewPlaying }
                var wrapped=false, previous=editor.previewPosition
                let deadline=Date().addingTimeInterval(4)
                while !wrapped, Date()<deadline {
                    try await Task.sleep(nanoseconds:20_000_000)
                    if editor.previewPosition<previous-0.1 { wrapped=true }
                    previous=editor.previewPosition
                }
                XCTAssertTrue(wrapped,"The bounded encoded sample must wrap in \(mode)")
                editor.auditionCut()
                try await wait { !editor.auditioning && !editor.previewPlaying && !editor.comparisonPreparing }
                XCTAssertEqual(editor.previewMode,mode)
                XCTAssertEqual(editor.start,start); XCTAssertEqual(editor.end,end)
                XCTAssertGreaterThan(editor.previewPosition,editor.previewDuration-0.05)
                if mode == .compare { XCTAssertEqual(editor.playback.frame?.pts,editor.end?.pts) }
            }
        }
    }
    @MainActor func testAuditionOutsideEncodedSampleReturnsToOriginal() async throws {
        let editor=open(); defer { editor.close() }
        try await wait { !editor.loading && !editor.playback.seeking }
        editor.preview(); try await wait({ !editor.exporting && editor.previewReady },timeout:20)
        XCTAssertLessThan(editor.previewStart+editor.previewDuration,editor.outTime)
        editor.auditionCut()
        XCTAssertEqual(editor.previewMode,.original)
        try await wait { !editor.auditioning && !editor.playback.seeking }
        XCTAssertEqual(editor.playback.frame?.pts,editor.end?.pts)
    }
}
