import AppKit
import XCTest
@testable import Clipper

final class UndoRedoTests:XCTestCase {
    private func fixture(_ name:String="cfr.mp4")->URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/fixtures/"+name)
    }
    @MainActor private func ready(_ editor:Editor) async throws {
        let deadline=Date().addingTimeInterval(8)
        while (editor.loading || editor.playback.seeking || editor.exporting), Date()<deadline { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(editor.loading); XCTAssertFalse(editor.playback.seeking); XCTAssertFalse(editor.exporting)
    }
    @MainActor private func opened(_ name:String="cfr.mp4") async throws -> Editor {
        let editor=Editor(); editor.open(fixture(name)); try await ready(editor)
        XCTAssertNotNil(editor.start); XCTAssertNotNil(editor.end)
        XCTAssertFalse(editor.canUndo); XCTAssertFalse(editor.editUndoManager.canUndo)
        return editor
    }
    @MainActor func testCompleteEditsUndoAndRedoInOrder() async throws {
        let editor=try await opened(); defer { editor.close() }
        var states=[editor.snapshot]
        editor.markStart(1); try await ready(editor); states.append(editor.snapshot)
        editor.markEnd(3); try await ready(editor); states.append(editor.snapshot)
        editor.updateSettings("Crop") { $0.cropPreset = .square }; states.append(editor.snapshot)
        editor.updateSettings("Crop") { $0.crop.size=CGSize(width:0.3,height:0.4); $0.crop.origin=CGPoint(x:0.2,y:0.25) }; states.append(editor.snapshot)
        editor.updateSettings("Crop") { $0.cropPreset = .custom }; states.append(editor.snapshot)
        editor.updateSettings("Crop Ratio") { $0.customWidth=4; $0.customHeight=3 }; states.append(editor.snapshot)
        editor.updateSettings("Quality") { $0.quality=81 }; states.append(editor.snapshot)
        editor.updateSettings("Exclude Audio") { $0.muted=true }; states.append(editor.snapshot)
        editor.updateSettings("Resolution") { $0.resolution = .tiny }; states.append(editor.snapshot)
        editor.updateSettings("Codec") { $0.codec = .hevc }; states.append(editor.snapshot)
        for state in states.dropLast().reversed() {
            XCTAssertTrue(editor.canUndo); editor.undoEdit(); try await ready(editor)
            XCTAssertEqual(editor.snapshot,state)
            XCTAssertEqual(editor.playback.endTime,editor.outTime)
            XCTAssertEqual(editor.playback.audio.isMuted,editor.edit.muted)
            XCTAssertEqual(editor.editUndoManager.groupingLevel,0)
        }
        XCTAssertFalse(editor.canUndo)
        for state in states.dropFirst() {
            XCTAssertTrue(editor.canRedo); editor.redoEdit(); try await ready(editor)
            XCTAssertEqual(editor.snapshot,state); XCTAssertEqual(editor.editUndoManager.groupingLevel,0)
        }
        XCTAssertFalse(editor.canRedo)
    }
    @MainActor func testNoOpsAndNewEditInvalidatesRedo() async throws {
        let editor=try await opened(); defer { editor.close() }
        editor.updateSettings("Quality") { $0.quality=65 }
        XCTAssertFalse(editor.canUndo)
        editor.updateSettings("Quality") { $0.quality=80 }; editor.undoEdit(); try await ready(editor)
        XCTAssertTrue(editor.canRedo)
        editor.updateSettings("Codec") { $0.codec = .h264 }
        XCTAssertTrue(editor.canRedo,"A no-op must preserve redo")
        editor.updateSettings("Resolution") { $0.resolution = .hd }
        XCTAssertFalse(editor.canRedo)
    }
    @MainActor func testQualityAndCropGesturesEachRecordOnce() async throws {
        let editor=try await opened(); defer { editor.close() }
        let before=editor.snapshot
        let slider=try XCTUnwrap(editor.beginEditGesture("Quality"))
        for value in 20...90 { editor.updateSettings("Quality",gesture:slider) { $0.quality=Double(value) } }
        XCTAssertFalse(editor.canUndo); XCTAssertFalse(editor.editUndoManager.canUndo)
        editor.endEditGesture(slider)
        let quality=editor.snapshot
        editor.updateSettings("Crop") { $0.cropPreset = .square }
        let preset=editor.snapshot
        let crop=try XCTUnwrap(editor.beginEditGesture("Crop"))
        for value in 1...20 { editor.updateSettings("Crop",gesture:crop) { $0.crop.origin.x=Double(value)/100 } }
        editor.endEditGesture(crop)
        let moved=editor.snapshot
        editor.undoEdit(); try await ready(editor); XCTAssertEqual(editor.snapshot,preset)
        editor.undoEdit(); try await ready(editor); XCTAssertEqual(editor.snapshot,quality)
        editor.undoEdit(); try await ready(editor); XCTAssertEqual(editor.snapshot,before); XCTAssertFalse(editor.canUndo)
        for _ in 0..<3 { editor.redoEdit(); try await ready(editor) }
        XCTAssertEqual(editor.snapshot,moved)
    }
    @MainActor func testTrimDragFinalRequestCompletesAfterMouseUpAsOneEntry() async throws {
        let editor=try await opened(); defer { editor.close() }
        let before=editor.snapshot, drag=try XCTUnwrap(editor.beginEditGesture("Trim Start"))
        for time in [0.3,0.6,0.9,1.2,1.5] { editor.markStart(time,gesture:drag) }
        editor.endEditGesture(drag)
        try await ready(editor)
        XCTAssertEqual(editor.inTime,1.5,accuracy:0.00001)
        let after=editor.snapshot
        editor.undoEdit(); try await ready(editor)
        XCTAssertEqual(editor.snapshot,before); XCTAssertFalse(editor.canUndo)
        editor.redoEdit(); try await ready(editor); XCTAssertEqual(editor.snapshot,after)
    }
    @MainActor func testUndoWaitsForClosingDragAndPreservesPreviousEdit() async throws {
        let editor=try await opened(); defer { editor.close() }
        editor.updateSettings("Quality") { $0.quality=85 }
        let drag=try XCTUnwrap(editor.beginEditGesture("Trim Start"))
        editor.markStart(2,gesture:drag); editor.endEditGesture(drag)
        XCTAssertFalse(editor.canUndo)
        editor.undoEdit(); try await ready(editor)
        XCTAssertEqual(editor.inTime,2,accuracy:0.00001); XCTAssertEqual(editor.edit.quality,85)
        editor.undoEdit(); try await ready(editor)
        XCTAssertEqual(editor.inTime,0); XCTAssertEqual(editor.edit.quality,85)
        editor.undoEdit(); try await ready(editor); XCTAssertEqual(editor.edit.quality,65)
    }
    @MainActor func testSupersedingSeekSettlesResolvedDragWithoutHanging() async throws {
        let editor=try await opened(); defer { editor.close() }
        let before=editor.snapshot, drag=try XCTUnwrap(editor.beginEditGesture("Trim Start"))
        editor.markStart(1,gesture:drag); try await ready(editor)
        editor.markStart(2,gesture:drag); editor.endEditGesture(drag)
        editor.seek(3); try await ready(editor)
        XCTAssertEqual(editor.inTime,1,accuracy:0.00001); XCTAssertTrue(editor.canUndo)
        editor.undoEdit(); try await ready(editor)
        XCTAssertEqual(editor.snapshot,before); XCTAssertFalse(editor.canUndo)
    }
    @MainActor func testRapidGesturesIgnoreOldEndAndOldUpdates() async throws {
        let editor=try await opened(); defer { editor.close() }
        let first=try XCTUnwrap(editor.beginEditGesture("Quality"))
        editor.updateSettings("Quality",gesture:first) { $0.quality=80 }
        let second=try XCTUnwrap(editor.beginEditGesture("Quality"))
        editor.endEditGesture(first)
        editor.updateSettings("Quality",gesture:first) { $0.quality=20 }
        editor.updateSettings("Quality",gesture:second) { $0.quality=90 }
        editor.endEditGesture(second)
        editor.undoEdit(); try await ready(editor); XCTAssertEqual(editor.edit.quality,80)
        editor.undoEdit(); try await ready(editor); XCTAssertEqual(editor.edit.quality,65); XCTAssertFalse(editor.canUndo)
    }
    @MainActor func testSourceReplacementResetsEvenWhenReopeningSameURL() async throws {
        let editor=try await opened(); defer { editor.close() }
        editor.updateSettings("Quality") { $0.quality=90 }
        let stale=try XCTUnwrap(editor.beginEditGesture("Trim"))
        editor.markStart(2,gesture:stale); editor.endEditGesture(stale)
        editor.open(fixture()); try await ready(editor)
        editor.endEditGesture(stale); editor.updateSettings("Quality",gesture:stale) { $0.quality=20 }
        XCTAssertEqual(editor.inTime,0); XCTAssertEqual(editor.edit.quality,65)
        XCTAssertFalse(editor.canUndo); XCTAssertFalse(editor.canRedo)
        editor.markEnd(2); try await ready(editor)
        editor.open(fixture("vfr.mkv")); try await ready(editor)
        XCTAssertFalse(editor.canUndo); XCTAssertFalse(editor.canRedo)
    }
    @MainActor func testNudgesAreIndividualAndInvalidTimestampRecordsNothing() async throws {
        let editor=try await opened(); defer { editor.close() }
        editor.nudgeBoundary(start:true,direction:1); editor.nudgeBoundary(start:true,direction:1)
        try await ready(editor)
        XCTAssertEqual(editor.inTime,2.0/24,accuracy:0.00001)
        editor.undoEdit(); try await ready(editor); XCTAssertEqual(editor.inTime,1.0/24,accuracy:0.00001)
        editor.undoEdit(); try await ready(editor); XCTAssertEqual(editor.inTime,0); XCTAssertFalse(editor.canUndo)
        editor.markEnd(1); try await ready(editor)
        let valid=editor.snapshot
        editor.markStart(4); try await ready(editor)
        XCTAssertEqual(editor.snapshot,valid); XCTAssertNotNil(editor.error)
        editor.undoEdit(); try await ready(editor); XCTAssertFalse(editor.canUndo)
    }
    @MainActor func testExportSettlesActiveGestureAndFreezesHistory() async throws {
        let editor=try await opened(); defer { editor.close() }
        let output=fixture("undo-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at:output) }
        editor.markEnd(0.5); try await ready(editor)
        let before=editor.snapshot, drag=try XCTUnwrap(editor.beginEditGesture("Crop"))
        editor.updateSettings("Crop",gesture:drag) { $0.cropPreset = .square }
        let exporting=editor.snapshot
        editor.export(to:output,replacingExisting:false)
        XCTAssertTrue(editor.exporting); XCTAssertFalse(editor.canUndo)
        editor.undoEdit(); editor.updateSettings("Quality") { $0.quality=20 }
        editor.endEditGesture(drag)
        XCTAssertEqual(editor.snapshot,exporting)
        try await ready(editor); XCTAssertNil(editor.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath:output.path))
        editor.undoEdit(); try await ready(editor); XCTAssertEqual(editor.snapshot,before)
    }
    @MainActor func testHistoryInvalidatesRenderedPreviewAndHDRRestoresAtomically() async throws {
        let editor=try await opened("hdr.mp4"); defer { editor.close() }
        XCTAssertEqual(editor.edit.codec,.hevc)
        editor.updateSettings("Convert to SDR") { $0.convertToSDR=true; $0.codec = .h264 }
        editor.markEnd(0.5); try await ready(editor)
        editor.preview(); try await ready(editor)
        XCTAssertNil(editor.error); XCTAssertNotNil(editor.previewURL)
        let preview=editor.previewURL
        editor.undoEdit(); try await ready(editor)
        XCTAssertNil(editor.previewURL); XCTAssertFalse(editor.previewReady); XCTAssertEqual(editor.previewMode,.original)
        if let preview { XCTAssertFalse(FileManager.default.fileExists(atPath:preview.path)) }
        editor.undoEdit(); try await ready(editor)
        XCTAssertFalse(editor.edit.convertToSDR); XCTAssertEqual(editor.edit.codec,.hevc)
        editor.redoEdit(); try await ready(editor)
        XCTAssertTrue(editor.edit.convertToSDR); XCTAssertEqual(editor.edit.codec,.h264)
    }
    @MainActor func testAudioTrackHistoryWaitsForReopen() async throws {
        let output=fixture("undo-audio-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at:output) }
        let process=Process()
        process.executableURL=fixture().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("media/bin/ffmpeg")
        process.arguments=["-v","error","-i",fixture().path,"-map","0:v","-map","0:a","-map","0:a","-c","copy",output.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        let editor=Editor(); editor.open(output); try await ready(editor)
        defer { editor.close() }
        XCTAssertEqual(editor.details?.audioLabels.count,2)
        let before=editor.snapshot
        editor.updateSettings("Audio Track") { $0.audioTrack=1 }
        XCTAssertTrue(editor.playback.seeking)
        XCTAssertFalse(editor.canUndo); editor.undoEdit()
        try await ready(editor); XCTAssertEqual(editor.edit.audioTrack,1)
        editor.undoEdit(); try await ready(editor)
        XCTAssertEqual(editor.snapshot,before); XCTAssertNil(editor.playback.error)
        editor.redoEdit(); try await ready(editor)
        XCTAssertEqual(editor.edit.audioTrack,1); XCTAssertEqual(editor.playback.endTime,editor.outTime)
    }
    @MainActor func testCommandsKeepNativeTextUndoSeparateFromClipHistory() async throws {
        _=NSApplication.shared
        let editor=try await opened(); defer { editor.close() }
        editor.updateSettings("Quality") { $0.quality=80 }
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:300,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let text=NSTextView(frame:window.contentView!.bounds); text.allowsUndo=true
        window.contentView=text; window.makeFirstResponder(text)
        defer { window.contentView=nil; window.close() }
        XCTAssertFalse(text.undoManager === editor.editUndoManager)
        text.insertText("Draft",replacementRange:NSRange(location:0,length:0)); text.breakUndoCoalescing()
        try await Task.sleep(nanoseconds:20_000_000)
        let commands=EditHistoryCommands(editor:editor)
        XCTAssertTrue(commands.isEnabled(redo:false,in:window))
        commands.perform(redo:false,in:window)
        XCTAssertEqual(text.string,""); XCTAssertEqual(editor.edit.quality,80)
        commands.perform(redo:true,in:window)
        XCTAssertEqual(text.string,"Draft"); XCTAssertEqual(editor.edit.quality,80)
        window.makeFirstResponder(nil)
        XCTAssertFalse(commands.usesTextUndo(in:window)); XCTAssertTrue(commands.isEnabled(redo:false,in:window))
        commands.perform(redo:false,in:window); try await ready(editor)
        XCTAssertEqual(editor.edit.quality,65); XCTAssertEqual(text.string,"Draft")
    }
    @MainActor func testOpeningImporterFreezesHistoryWithoutResettingIt() async throws {
        let editor=try await opened(); defer { editor.close() }
        editor.updateSettings("Quality") { $0.quality=80 }
        editor.showURLImporter()
        XCTAssertFalse(editor.canUndo)
        editor.undoEdit(); XCTAssertEqual(editor.edit.quality,80)
        editor.importPresented=false
        XCTAssertTrue(editor.canUndo)
        editor.undoEdit(); try await ready(editor); XCTAssertEqual(editor.edit.quality,65)
        editor.close(); XCTAssertFalse(editor.editUndoManager.canUndo); XCTAssertFalse(editor.editUndoManager.canRedo)
    }
    @MainActor func testPendingMarksSurviveStepPlayAndSettings() async throws {
        let editor=try await opened(); defer { editor.close() }
        editor.markStart(1); editor.stepFrame(1); try await ready(editor)
        XCTAssertEqual(editor.inTime,1,accuracy:0.00001)
        editor.markStart(2); editor.togglePlayback(); try await ready(editor)
        XCTAssertEqual(editor.inTime,2,accuracy:0.00001)
        editor.playback.pause()
        editor.markEnd(4); editor.updateSettings("Quality") { $0.quality=80 }; try await ready(editor)
        XCTAssertEqual(editor.end?.time ?? 0,4,accuracy:0.00001); XCTAssertEqual(editor.edit.quality,80)
    }
    @MainActor func testUndoIsDisabledWhilePlainMarkResolves() async throws {
        let editor=try await opened(); defer { editor.close() }
        editor.updateSettings("Quality") { $0.quality=80 }
        editor.markStart(2)
        XCTAssertFalse(editor.canUndo); editor.undoEdit(); try await ready(editor)
        XCTAssertEqual(editor.inTime,2,accuracy:0.00001); XCTAssertEqual(editor.edit.quality,80)
        editor.undoEdit(); try await ready(editor)
        XCTAssertEqual(editor.inTime,0); XCTAssertEqual(editor.edit.quality,80)
    }
    @MainActor func testNudgesAreIgnoredWhileImporterIsOpen() async throws {
        let editor=try await opened(); defer { editor.close() }
        editor.showURLImporter(); editor.nudgeBoundary(start:true,direction:1)
        try await ready(editor)
        XCTAssertEqual(editor.inTime,0); XCTAssertFalse(editor.editUndoManager.canUndo)
        editor.importPresented=false
    }
    @MainActor func testGestureCannotMergeWithAnUnresolvedDiscreteMark() async throws {
        let editor=try await opened(); defer { editor.close() }
        editor.markStart(1)
        XCTAssertNil(editor.beginEditGesture("Quality"))
        try await ready(editor)
        XCTAssertEqual(editor.inTime,1,accuracy:0.00001)
        let gesture=try XCTUnwrap(editor.beginEditGesture("Quality"))
        editor.updateSettings("Quality",gesture:gesture) { $0.quality=80 }
        editor.endEditGesture(gesture)
        editor.undoEdit(); try await ready(editor)
        XCTAssertEqual(editor.inTime,1,accuracy:0.00001); XCTAssertEqual(editor.edit.quality,65)
        editor.undoEdit(); try await ready(editor)
        XCTAssertEqual(editor.inTime,0); XCTAssertFalse(editor.canUndo)
    }
    func testNormalizationProducesValidCompleteSettings() {
        let details=MediaDetails(duration:5,origin:0,width:1920,height:1080,rotation:0,pixelAspect:1,fps:24,hdr:true,codec:"hevc",audioLabels:["a","b"],audioStreams:[0,1])
        for preset in CropPreset.allCases {
            let old=EditSettings(); var edit=old; edit.cropPreset=preset
            edit.customWidth=4; edit.customHeight=3; edit.audioTrack=99
            edit.normalize(previous:old,details:details)
            XCTAssertEqual(edit.codec,.hevc); XCTAssertEqual(edit.audioTrack,1)
            XCTAssertGreaterThan(edit.crop.width,0); XCTAssertGreaterThan(edit.crop.height,0)
            XCTAssertTrue(CGRect(x:0,y:0,width:1,height:1).contains(edit.crop))
            if preset != .original {
                XCTAssertEqual(edit.crop.width*1920/(edit.crop.height*1080),preset == .custom ? 4/3 : preset.ratio!,accuracy:0.00001)
            }
        }
        let old=EditSettings(); var invalid=old
        invalid.customWidth = .nan; invalid.customHeight=0; invalid.quality = .infinity
        invalid.crop=CGRect(x:0,y:0,width:Double.nan,height:1)
        invalid.normalize(previous:old,details:details)
        XCTAssertEqual(invalid.crop,old.crop); XCTAssertEqual(invalid.customWidth,16); XCTAssertEqual(invalid.customHeight,9); XCTAssertEqual(invalid.quality,65)
    }
}
