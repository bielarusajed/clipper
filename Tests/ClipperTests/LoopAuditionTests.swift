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
        let defaults=UserDefaults(suiteName:"Clipper.LoopTests."+UUID().uuidString)!
        let editor=Editor(preferences:ExportPreferences(defaults:defaults)); editor.open(fixture(name)); return editor
    }
    @MainActor private func select(_ editor:Editor,start:Double,end:Double) async throws {
        try await wait { !editor.loading && !editor.playback.seeking }
        editor.markStart(start); try await wait { !editor.playback.seeking }
        editor.markEnd(end); try await wait { !editor.playback.seeking }
        editor.seek(editor.inTime); try await wait { !editor.playback.seeking }
    }
    // Observe operations while forwarding to the same real renderer as production.
    private final class VideoSamples:VideoOutput {
        private let lock=NSLock()
        nonisolated(unsafe) private var times:[Double]=[]
        var imageRemovals=0
        nonisolated(unsafe) private var flushes=0
        var flushCount:Int { lock.withLock { flushes } }
        override func flush() { lock.withLock { flushes += 1 }; super.flush() }
        nonisolated(unsafe) var renderClock:AVSampleBufferRenderSynchronizer?
        nonisolated(unsafe) private var lead:[(Double,Double)]=[]
        var enqueueLead:[(Double,Double)] { lock.withLock { lead } }
        var timestamps:[Double] { lock.withLock { times } }
        override func enqueue(_ buffer:CMSampleBuffer) {
            lock.withLock {
                let time=CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                times.append(time)
                if let renderClock, renderClock.rate>0 { lead.append((time,time-renderClock.currentTime().seconds)) }
            }
            super.enqueue(buffer)
        }
        override func removeImage() { imageRemovals += 1; super.removeImage() }
    }
    private final class AudioSamples:AVSampleBufferAudioRenderer {
        private let lock=NSLock()
        nonisolated(unsafe) private var ends:[Double]=[]
        nonisolated(unsafe) private var starts:[Double]=[]
        var startTimes:[Double] { lock.withLock { starts } }
        var endTimes:[Double] { lock.withLock { ends } }
        nonisolated override func enqueue(_ buffer:CMSampleBuffer) {
            lock.withLock {
                starts.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                ends.append((CMSampleBufferGetPresentationTimeStamp(buffer)+CMSampleBufferGetDuration(buffer)).seconds)
            }
            super.enqueue(buffer)
        }
    }
    private final class RateHistory {
        private let lock=NSLock()
        private var recorded:[Float]=[]
        var rates:[Float] { lock.withLock { recorded } }
        func observe(_ clock:AVSampleBufferRenderSynchronizer)->NSKeyValueObservation {
            clock.observe(\.rate,options:[.initial,.new]) { [self] clock,_ in lock.withLock { recorded.append(clock.rate) } }
        }
    }
    @MainActor func testDecoderEnforcesExclusiveCutForVideoAndAudioAndRetainsImage() async throws {
        let video=VideoSamples(), audio=AudioSamples(), player=Playback(videoOutput:video,audio:audio)
        defer { player.close() }
        var opened=false
        player.open(fixture("cfr.mp4"),at:1,completion:{ opened=true })
        try await wait { opened }
        let removals=video.imageRemovals
        let end=1+3.0/24
        var finished=false
        player.playRange(until:end,loopStart:1,looping:true,onEnd:{ finished=true })
        try await wait { player.clock.rate>0 }
        try await Task.sleep(nanoseconds:600_000_000)
        XCTAssertFalse(player.loopGap)
        for pass in 0..<3 {
            let last=end-1.0/24+Double(pass)*(end-1)
            XCTAssertTrue(video.timestamps.contains { abs($0-last)<0.000001 },"The last included B-frame must be enqueued in every pass")
        }
        player.setLooping(false)
        try await wait { finished }
        XCTAssertFalse(video.timestamps.isEmpty); XCTAssertFalse(audio.endTimes.isEmpty)
        for (end,start) in zip(audio.endTimes,audio.startTimes.dropFirst()) {
            XCTAssertEqual(end,start,accuracy:1.0/48000,"PCM must be contiguous across the wrap")
        }
        XCTAssertEqual(video.imageRemovals,removals,"Wraps must keep the image visible")
        XCTAssertFalse(player.transportWanted)
    }
    @MainActor func testLoopClockNeverStopsOrRewindsAcrossWraps() async throws {
        let player=Playback()
        defer { player.close() }
        var opened=false
        player.open(fixture("cfr.mp4"),at:1,completion:{ opened=true })
        try await wait { opened }
        player.playRange(until:1.25,loopStart:1,looping:true)
        try await wait { player.clock.rate>0 }
        let history=RateHistory()
        let rateObservation=history.observe(player.clock)
        var stopped=0
        let observation=player.$playing.dropFirst().sink { if !$0 && player.transportWanted { stopped += 1 } }
        let beginning=player.clock.currentTime().seconds
        try await Task.sleep(nanoseconds:800_000_000)
        XCTAssertTrue(history.rates.allSatisfy { $0==1 })
        rateObservation.invalidate()
        XCTAssertEqual(stopped,0,"A wrap must not pause transport while preparing the next pass")
        XCTAssertGreaterThan(player.clock.currentTime().seconds-beginning,0.7,"Renderer time must stay continuous across wraps")
        observation.cancel()
    }
    @MainActor func testReal4KSelectionLoopsContinuouslyWhenProvided() async throws {
        guard let path=ProcessInfo.processInfo.environment["CLIPPER_SAMPLE"] else { throw XCTSkip("Set CLIPPER_SAMPLE to check the original 4K AV1 selection") }
        let video=VideoSamples(), audio=AudioSamples(), player=Playback(videoOutput:video,audio:audio)
        defer { player.close() }
        video.renderClock=player.clock
        var opened=false
        player.open(URL(fileURLWithPath:path),at:499.874,completion:{ opened=true })
        try await wait({ opened },timeout:30)
        let end=try XCTUnwrap(player.frame).end
        player.seek(493.257)
        try await wait({ !player.seeking },timeout:30)
        let start=try XCTUnwrap(player.frame).time
        player.playRange(until:end,loopStart:start,looping:true)
        try await wait({ player.clock.rate>0 },timeout:30)
        let history=RateHistory()
        let rateObservation=history.observe(player.clock)
        var stopped=0
        let observation=player.$playing.dropFirst().sink { if !$0 && player.transportWanted { stopped += 1 } }
        let beginning=player.clock.currentTime().seconds, flushes=video.flushCount
        try await Task.sleep(nanoseconds:UInt64((2*(end-start)+0.5)*1_000_000_000))
        XCTAssertEqual(stopped,0)
        XCTAssertTrue(history.rates.allSatisfy { $0==1 })
        rateObservation.invalidate()
        XCTAssertEqual(video.flushCount,flushes,"No display-layer flush at a loop seam")
        XCTAssertFalse(player.loopGap,"The spare must be ready before each wrap")
        XCTAssertGreaterThan(player.clock.currentTime().seconds-beginning,2*(end-start))
        for pass in 1...2 {
            let boundary=end+Double(pass-1)*(end-start)
            let first=try XCTUnwrap(video.timestamps.first { $0>=boundary-0.000001 })
            XCTAssertEqual(first,boundary,accuracy:0.000002,"No missing video time at the seam")
            let margins=video.enqueueLead.filter { $0.0>=boundary && $0.0<boundary+0.1 }.map { $0.1 }
            XCTAssertGreaterThan(try XCTUnwrap(margins.min()),0.05,"Loop head must reach the renderer before its deadline")
        }
        for (end,start) in zip(audio.endTimes,audio.startTimes.dropFirst()) {
            XCTAssertEqual(end,start,accuracy:1.0/48000+0.000001,"No inserted PCM gap at the cut")
        }
        print("Continuous 4K loop: period \(end-start) s, clock advanced \(player.clock.currentTime().seconds-beginning) s, transport pauses \(stopped)")
        observation.cancel()
    }
    @MainActor func testHundredSingleFramePassesAndWarmResumeKeepTimeline() async throws {
        let video=VideoSamples(), audio=AudioSamples(), player=Playback(videoOutput:video,audio:audio)
        defer { player.close() }
        var opened=false
        player.open(fixture("cfr.mp4"),at:1,completion:{ opened=true })
        try await wait { opened }
        player.playRange(until:1+1.0/24,loopStart:1,looping:true)
        try await wait { player.clock.rate>0 }
        let first=player.clock.currentTime().seconds, flushes=video.flushCount
        try await Task.sleep(nanoseconds:4_300_000_000)
        XCTAssertGreaterThanOrEqual(video.timestamps.count,100)
        XCTAssertGreaterThan(player.clock.currentTime().seconds-first,4.2)
        XCTAssertFalse(player.loopGap)
        XCTAssertEqual(video.flushCount,flushes)
        player.pause()
        XCTAssertEqual(player.frame?.time ?? -1,1,accuracy:0.000001)
        let paused=player.clock.currentTime().seconds, resumed=Date()
        player.playRange(until:1+1.0/24,loopStart:1,looping:true)
        try await wait { player.clock.rate>0 }
        XCTAssertLessThan(Date().timeIntervalSince(resumed),0.12)
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertGreaterThan(player.clock.currentTime().seconds,paused+0.1)
        XCTAssertEqual(video.flushCount,flushes)
        player.setLooping(false)
        try await wait { !player.transportWanted && !player.seeking }
    }
    @MainActor func testRapidLoopReenableWhilePlayingAndPausedDoesNotStop() async throws {
        let editor=open(); defer { editor.close() }
        try await select(editor,start:1,end:1.49)
        editor.toggleLoop(); editor.togglePlayback()
        try await wait { editor.playback.clock.rate>0 }
        editor.toggleLoop(); editor.toggleLoop()
        try await Task.sleep(nanoseconds:1_200_000_000)
        XCTAssertTrue(editor.loopEnabled); XCTAssertTrue(editor.isPlaying)
        XCTAssertEqual(editor.playback.clock.rate,1)
        editor.togglePlayback()
        editor.toggleLoop(); editor.toggleLoop()
        editor.togglePlayback()
        try await Task.sleep(nanoseconds:1_200_000_000)
        XCTAssertTrue(editor.loopEnabled); XCTAssertTrue(editor.isPlaying)
        XCTAssertEqual(editor.playback.clock.rate,1)
    }
    @MainActor func testPreparationCancellationCannotReturnOldSource() async throws {
        for _ in 0..<15 {
            let preparation=LoopPreparation()
            preparation.prepare(url:fixture("cfr.mp4"),audioTrack:0,start:0)
            try await Task.sleep(nanoseconds:15_000_000)
            preparation.cancel()
            XCTAssertNil(preparation.take(),"Cancellation must remove the ready lane synchronously")
            preparation.prepare(url:fixture("vfr.mkv"),audioTrack:0,start:0)
            preparation.cancel()
            XCTAssertNil(preparation.take())
        }
        let editor=open(); defer { editor.close() }
        try await select(editor,start:1,end:1.12)
        for _ in 0..<12 {
            editor.toggleLoop(); editor.togglePlayback()
            editor.close()
            try await Task.sleep(nanoseconds:10_000_000)
            XCTAssertNil(editor.source); XCTAssertNil(editor.playback.frame)
            XCTAssertFalse(editor.isPlaying)
            editor.open(fixture("vfr.mkv"))
            try await wait { !editor.loading && !editor.playback.seeking }
        }
    }
    @MainActor func testSameFrameSeekAfterPauseKeepsWarmDecoderRunning() async throws {
        let video=VideoSamples()
        let player=Playback(videoOutput:video)
        defer { player.close() }
        var opened=false
        player.open(fixture("cfr.mp4"),at:1,completion:{ opened=true })
        try await wait { opened }
        player.playRange(until:4,loopStart:1,looping:true)
        try await wait { player.clock.rate>0 }
        try await Task.sleep(nanoseconds:160_000_000)
        player.pause()
        let paused=try XCTUnwrap(player.frame)
        player.seek(paused.time+0.000002)
        XCTAssertFalse(player.seeking,"Same-frame seeks should retain warm queued media")
        player.playRange(until:4,loopStart:1,looping:true)
        try await wait { player.clock.rate>0 }
        try await Task.sleep(nanoseconds:900_000_000)
        XCTAssertGreaterThan(player.position,paused.time+0.7)
        XCTAssertGreaterThan(video.timestamps.max() ?? 0,paused.time+0.7,"Fresh frames must be enqueued after the existing warm queue drains")
        XCTAssertTrue(player.playing)
    }
    @MainActor func testUndoTrimWhileLoopingStopsAndRestoresSelection() async throws {
        let editor=open(); defer { editor.close() }
        try await select(editor,start:1,end:1.49)
        let end=editor.end
        editor.markEnd(1.7); try await wait { !editor.playback.seeking }
        editor.toggleLoop(); editor.togglePlayback()
        try await wait { editor.playback.clock.rate>0 }
        editor.undoEdit()
        try await wait { !editor.playback.seeking }
        XCTAssertEqual(editor.end,end)
        XCTAssertFalse(editor.isPlaying); XCTAssertFalse(editor.auditioning)
        editor.redoEdit(); try await wait { !editor.playback.seeking }
        XCTAssertGreaterThan(editor.outTime,end!.end)
        editor.togglePlayback(); try await wait { editor.playback.clock.rate>0 }
    }
    @MainActor func testSubtitleCueReturnsAfterContinuousLoopWraps() async throws {
        let editor=open(); defer { editor.close() }
        try await select(editor,start:1,end:1.49)
        let directory=try SubtitleDirectory()
        let text=SubtitleComposer.compose("""
        [Script Info]
        ScriptType: v4.00+
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:01.50,Default,,0,0,0,,Loop cue
        """,style:SubtitleStyle(),width:160,height:90)
        let asset=try RenderSubtitles(directory:directory,text:text,zero:0,preserve:false)
        let surface=ComparisonSurface.Surface(source:editor.playback.video,player:editor.outputPlayer)
        defer { ComparisonSurface.dismantleNSView(surface,coordinator:()) }
        surface.details=editor.details; surface.playback=editor.playback
        surface.subtitleAsset=asset; surface.frame=CGRect(x:0,y:0,width:320,height:180)
        surface.layoutSubtreeIfNeeded()
        editor.toggleLoop(); editor.togglePlayback()
        try await wait { editor.playback.clock.rate>0 }
        try await Task.sleep(nanoseconds:1_200_000_000)
        XCTAssertGreaterThan(editor.playback.clock.currentTime().seconds,2)
        XCTAssertGreaterThanOrEqual(editor.playback.currentSourceTime,1)
        XCTAssertLessThan(editor.playback.currentSourceTime,1.5)
        XCTAssertNotNil(surface.subtitleLayer.contents,"The cue must render from source time on the third pass")
    }
    @MainActor func testShortAndVFRSelectionsLoopWithoutChangingMarkers() async throws {
        for name in ["cfr.mp4","vfr.mkv"] {
            let editor=open(name); defer { editor.close() }
            try await select(editor,start:1,end:1.12)
            let start=editor.start, end=editor.end
            var passes=0
            var previous=editor.playback.position
            let observation=editor.playback.$position.dropFirst().sink { value in
                if value<previous-0.001 { passes += 1 }; previous=value
            }
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
        var previous=editor.playback.position
        let observation=editor.playback.$position.dropFirst().sink { value in
            if value<previous-0.001 { wraps += 1 }; previous=value
        }
        editor.toggleLoop(); editor.togglePlayback()
        try await wait { wraps>=3 && editor.playback.clock.rate>0 }
        editor.updateSettings("Mute") { $0.muted.toggle() }
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
        try await wait { editor.playback.clock.rate>0 }
        try await Task.sleep(nanoseconds:180_000_000)
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
        for _ in 0..<11 { editor.toggleLoop() }
        editor.togglePlayback()
        try await wait { editor.playback.clock.rate>0 }
        try await Task.sleep(nanoseconds:300_000_000)
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
