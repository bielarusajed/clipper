import AppKit
import XCTest
@testable import Clipper

final class ExportHandoffTests:XCTestCase {
    private var root:URL!
    override func setUpWithError() throws {
        root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/export-handoff-tests/\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }

    private func file(_ name:String,contents:String="exported bytes") throws -> URL {
        let url=root.appendingPathComponent(name)
        try Data(contents.utf8).write(to:url)
        return url
    }
    private func withPasteboard(_ body:(NSPasteboard) throws -> Void) rethrows {
        let board=NSPasteboard(name:.init("ClipperExportHandoffTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        try body(board)
    }
    private func readFile(_ board:NSPasteboard) -> URL? {
        (board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true])?.first as? URL)
    }

    @MainActor func testCopyAndDragWriterRoundTripRealFileURL() throws {
        let url=try file("A clip with spaces.mp4")
        let clip=ExportedClip(); clip.set(url)
        try withPasteboard { board in
            XCTAssertTrue(clip.copy(to:board))
            XCTAssertTrue(board.types?.contains(.fileURL) == true)
            XCTAssertEqual(readFile(board),url)
            XCTAssertEqual(try Data(contentsOf:XCTUnwrap(readFile(board))),Data("exported bytes".utf8))
            board.clearContents()
            // This is the exact writer used by NSDraggingItem, not a path string.
            XCTAssertTrue(board.writeObjects([try XCTUnwrap(clip.pasteboardWriter())]))
            XCTAssertTrue(board.types?.contains(.fileURL) == true)
            XCTAssertEqual(readFile(board),url)
        }
        XCTAssertEqual(ExportedClip.dragOperationMask(for:.outsideApplication),.copy)
        XCTAssertEqual(ExportedClip.dragOperationMask(for:.withinApplication),[])
    }

    @MainActor func testMissingMovedAndDirectoryExportsDoNotTouchPasteboard() throws {
        let url=try file("clip.mp4")
        let clip=ExportedClip(); clip.set(url)
        try withPasteboard { board in
            board.setString("keep existing clipboard",forType:.string)
            let moved=root.appendingPathComponent("moved.mp4")
            try FileManager.default.moveItem(at:url,to:moved)
            XCTAssertNil(clip.currentURL()); XCTAssertFalse(clip.available)
            XCTAssertNil(clip.pasteboardWriter()); XCTAssertFalse(clip.copy(to:board))
            XCTAssertEqual(board.string(forType:.string),"keep existing clipboard")
            try FileManager.default.moveItem(at:moved,to:url)
            XCTAssertEqual(clip.currentURL(),url)
            try FileManager.default.removeItem(at:url)
            XCTAssertNil(clip.pasteboardWriter())
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
            XCTAssertFalse(clip.copy(to:board)); XCTAssertFalse(clip.available)
        }
    }

    @MainActor func testReplacementAndResetUseLatestFile() throws {
        let first=try file("first.mp4"), second=try file("second.mp4")
        let clip=ExportedClip(); clip.set(first); clip.set(second)
        try withPasteboard { board in
            XCTAssertTrue(clip.copy(to:board)); XCTAssertEqual(readFile(board),second)
            let replacement=try file("replacement.mp4",contents:"replacement bytes")
            try ExportDestination.publish(replacement,to:second,source:first,replacingExisting:true)
            XCTAssertTrue(clip.copy(to:board)); XCTAssertEqual(readFile(board),second)
            XCTAssertEqual(try Data(contentsOf:XCTUnwrap(readFile(board))),Data("replacement bytes".utf8))
            clip.set(nil)
            XCTAssertFalse(clip.available); XCTAssertNil(clip.pasteboardWriter())
            XCTAssertFalse(clip.copy(to:board))
            XCTAssertEqual(readFile(board),second,"Closing the source doesn't clear the clipboard")
        }
    }

    func testManagedDirectoriesRejectChildrenAliasesAndNonexistentParents() throws {
        let managed=root.appendingPathComponent("Imports",isDirectory:true)
        let child=managed.appendingPathComponent("Job",isDirectory:true)
        try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        let alias=root.appendingPathComponent("alias",isDirectory:true)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:child)
        let source=try file("source.mp4")
        var directories=[managed,child,alias,child.appendingPathComponent("not-created",isDirectory:true),alias.appendingPathComponent("not-created",isDirectory:true)]
        let privatePath=URL(fileURLWithPath:"/private"+managed.path)
        // The volume may be case-sensitive; check aliases only when they exist.
        if FileManager.default.fileExists(atPath:privatePath.path) { directories.append(privatePath) }
        let alternateCase=managed.deletingLastPathComponent().appendingPathComponent("IMPORTS")
        if FileManager.default.fileExists(atPath:alternateCase.path) { directories.append(alternateCase) }
        for directory in directories {
            XCTAssertThrowsError(try ExportDestination.validate(source:source,destination:directory.appendingPathComponent("output.mp4"),managedDirectories:[managed]),directory.path)
        }
        let outside=root.appendingPathComponent("preview.mp4")
        XCTAssertNoThrow(try ExportDestination.validate(source:source,destination:outside,managedDirectories:[managed]))
        let rendered=try file("rendered.mp4")
        XCTAssertThrowsError(try ExportDestination.publish(rendered,to:alias.appendingPathComponent("output.mp4"),source:source,replacingExisting:false,managedDirectories:[managed]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:rendered.path))
    }

    @MainActor func testEditorExportsCopyDragAndSurviveManagedCleanup() async throws {
        let files=FileManager.default
        let directory=root.appendingPathComponent("import",isDirectory:true)
        try files.createDirectory(at:directory,withIntermediateDirectories:true)
        let fixture=URL(fileURLWithPath:files.currentDirectoryPath).appendingPathComponent(".build/fixtures/cfr.mp4")
        let source=directory.appendingPathComponent("Source.mp4")
        try files.copyItem(at:fixture,to:source)
        let editor=Editor()
        editor.open(source,temporary:TemporaryImport(directory:directory,file:source))
        defer { editor.close() }
        try await wait { editor.canExport }
        editor.markEnd(0.99)
        try await wait { editor.canExport }
        let rejected=directory.appendingPathComponent("do-not-dispose.mp4")
        editor.export(to:rejected,replacingExisting:false)
        XCTAssertNotNil(editor.error); XCTAssertFalse(editor.exporting)
        XCTAssertFalse(files.fileExists(atPath:rejected.path))

        let first=root.appendingPathComponent("first.mp4"), second=root.appendingPathComponent("second.mp4")
        for output in [first,second] {
            editor.export(to:output,replacingExisting:false)
            try await wait { !editor.exporting }
            XCTAssertNil(editor.error); XCTAssertEqual(editor.lastExport,output)
        }
        editor.export(to:source,replacingExisting:true)
        XCTAssertNotNil(editor.error); XCTAssertEqual(editor.lastExport,second)
        editor.export(to:second,replacingExisting:true); editor.cancel()
        try await wait { !editor.exporting }
        XCTAssertEqual(editor.lastExport,second)
        editor.preview()
        try await wait { !editor.exporting }
        XCTAssertNil(editor.error); XCTAssertEqual(editor.lastExport,second,"Preview isn't a new exported clip")

        try withPasteboard { board in
            XCTAssertTrue(editor.exportedClip.copy(to:board))
            let writer=try XCTUnwrap(editor.exportedClip.pasteboardWriter())
            editor.prepareToQuit()
            XCTAssertNil(editor.lastExport)
            XCTAssertEqual(readFile(board),second)
            XCTAssertTrue(files.fileExists(atPath:second.path))
            board.clearContents(); XCTAssertTrue(board.writeObjects([writer]))
            XCTAssertEqual(readFile(board),second)
        }
        await withCheckedContinuation { continuation in editor.playback.queue.async { continuation.resume() } }
        XCTAssertFalse(files.fileExists(atPath:directory.path))
        XCTAssertTrue(files.fileExists(atPath:first.path))
        XCTAssertTrue(files.fileExists(atPath:second.path))
    }

    @MainActor private func wait(_ condition:() -> Bool) async throws {
        let deadline=Date().addingTimeInterval(15)
        while !condition() {
            if Date()>deadline { XCTFail("Timed out waiting for editor"); throw ExportFailure.message("Test timed out") }
            try await Task.sleep(for:.milliseconds(20))
        }
    }
}
