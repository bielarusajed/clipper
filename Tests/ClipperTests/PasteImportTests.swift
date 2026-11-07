import AppKit
import SwiftUI
import XCTest
@testable import Clipper

final class PasteImportTests:XCTestCase {
    @MainActor func testClipboardReadsFinderFilesFileURLsPathsAndWebLinks() throws {
        let files=FileManager.default
        let directory=files.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try files.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? files.removeItem(at:directory) }
        let file=directory.appendingPathComponent("A video with spaces.mp4")
        try Data("fixture".utf8).write(to:file)
        let pasteboard=NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([file as NSURL]))
        XCTAssertEqual(ClipboardImport.read(pasteboard),.file(file))
        for text in [file.path,"\"\(file.path)\"",file.absoluteString] {
            pasteboard.clearContents(); pasteboard.setString(text,forType:.string)
            XCTAssertEqual(ClipboardImport.read(pasteboard),.file(file))
        }
        pasteboard.clearContents()
        let web=URL(string:"https://example.com/watch?v=1")!
        pasteboard.writeObjects([web as NSURL])
        XCTAssertEqual(ClipboardImport.read(pasteboard),.web(web))
        XCTAssertEqual(ClipboardImport.parse("Watch this: https://example.com/watch?v=1"),.web(web))
        XCTAssertNil(ClipboardImport.parse("https://example.com/a https://example.com/b"))
        XCTAssertNil(ClipboardImport.parse("ordinary clipboard text"))
        XCTAssertNil(ClipboardImport.parse("/definitely-missing/video.mp4"))
        XCTAssertNil(ClipboardImport.parse(directory.path))
        let textFile=directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to:textFile)
        XCTAssertNil(ClipboardImport.parse(textFile.path))
    }

    @MainActor func testFilePasteOpensVideoAndModalPasteIsIgnored() async throws {
        let fixture=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/fixtures/cfr.mp4")
        let editor=Editor()
        editor.paste(.file(fixture))
        XCTAssertEqual(editor.source,fixture)
        XCTAssertFalse(editor.importPresented)
        editor.showURLImporter()
        XCTAssertFalse(editor.canPasteImport)
        editor.paste(.file(fixture.deletingLastPathComponent().appendingPathComponent("av1.webm")))
        XCTAssertEqual(editor.source,fixture)
        editor.importPresented=false; editor.close()
        await withCheckedContinuation { continuation in editor.playback.queue.async { continuation.resume() } }
    }

    @MainActor func testPastedURLPrefetchStaysCompactAndExpansionReusesInFlightLookup() async throws {
        let service=ImportServiceSpy()
        let model=URLImport(service:service)
        let url=URL(string:"https://example.com/one")!
        model.begin(url:url)
        model.urlChanged() // SwiftUI observes the prefill after the lookup was started.
        XCTAssertEqual(model.urlText,url.absoluteString)
        XCTAssertFalse(model.formatsVisible)
        XCTAssertTrue(model.busy)
        XCTAssertFalse(model.showsActivity,"Passive prefetch must leave Download and Choose formats available")
        try await waitUntil { await service.lookupCount == 1 }
        model.showFormats(); model.showFormats()
        XCTAssertTrue(model.formatsVisible)
        XCTAssertTrue(model.showsActivity,"Opening formats must reveal the existing lookup's status")
        XCTAssertFalse(model.status.isEmpty)
        assertEqual(await service.lookupCount,1)
        await service.releaseLookup()
        try await waitUntil { !model.busy }
        XCTAssertNotNil(model.media)
        XCTAssertFalse(model.showsActivity)
        model.showFormats()
        assertEqual(await service.lookupCount,1)
        assertEqual(await service.downloadCount,0)
    }

    @MainActor func testDownloadWhilePrefetchingQueuesOneDefaultDownload() async throws {
        let service=ImportServiceSpy()
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/one")!)
        try await waitUntil { await service.lookupCount == 1 }
        var opened=0
        model.download { _ in opened += 1; XCTAssertFalse(model.busy) }
        model.download { _ in XCTFail("Repeated click must not queue a second download") }
        XCTAssertTrue(model.downloadRequested)
        XCTAssertTrue(model.showsActivity,"Requesting Download must reveal status without duplicating the lookup")
        XCTAssertFalse(model.status.isEmpty)
        model.showFormats()
        assertEqual(await service.lookupCount,1)
        assertEqual(await service.downloadCount,0)
        await service.releaseLookup()
        try await waitUntil { await service.downloadCount == 1 }
        model.showFormats()
        XCTAssertTrue(model.formatsVisible)
        assertEqual(await service.lookupCount,1)
        await service.releaseDownload()
        try await waitUntil { !model.busy }
        assertEqual(await service.selectors,["bv+ba/b"])
        XCTAssertEqual(opened,1)
        XCTAssertFalse(model.downloadRequested)
    }

    @MainActor func testCompletedPrefetchDownloadsManualSelectionWithoutAnotherLookup() async throws {
        let service=ImportServiceSpy()
        await service.releaseLookup(); await service.releaseDownload()
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/one")!)
        try await waitUntil { !model.busy }
        model.showFormats(); model.selectVideo("137"); model.audio="none"
        model.download { _ in }
        try await waitUntil { !model.busy }
        assertEqual(await service.lookupCount,1)
        assertEqual(await service.selectors,["137"])
        assertEqual(await service.excludedAudio,[true])
    }

    @MainActor func testCancellingQueuedDownloadPreventsItAndURLChangesCancelOldLookups() async throws {
        let service=ImportServiceSpy()
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/old")!)
        try await waitUntil { await service.lookupCount == 1 }
        model.download { _ in XCTFail("Cancelled lookup must not open a video") }
        await model.cancelAndWait()
        XCTAssertFalse(model.busy)
        assertEqual(await service.downloadCount,0)
        model.begin(url:URL(string:"https://example.com/next")!)
        try await waitUntil { await service.lookupCount == 2 }
        model.urlText="https://example.com/newest"
        // Simulate Return before SwiftUI's onChange callback.
        model.download { _ in }
        try await waitUntil { await service.lookupCount == 3 }
        await service.releaseLookup(); await service.releaseDownload()
        try await waitUntil { !model.busy }
        XCTAssertEqual(model.media?.id,"https://example.com/newest")
        assertEqual(await service.downloadURLs,[URL(string:"https://example.com/newest")!])
    }

    @MainActor func testClosingDuringBackgroundLookupCancelsAndDoesNotReopen() async throws {
        let service=ImportServiceSpy()
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/one")!)
        try await waitUntil { await service.lookupCount == 1 }
        model.endPresentation()
        XCTAssertFalse(model.busy)
        await service.releaseLookup()
        try await waitUntil { await service.cancelledLookups == 1 }
        XCTAssertNil(model.media)
        XCTAssertFalse(model.formatsVisible)
        assertEqual(await service.downloadCount,0)
    }

    private func assertEqual<T:Equatable>(_ actual:T,_ expected:T,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertEqual(actual,expected,file:file,line:line)
    }

    @MainActor func testClosingDuringDownloadCancelsAndNeverOpensTheResult() async throws {
        let service=ImportServiceSpy()
        await service.releaseLookup()
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/one")!)
        model.download { _ in XCTFail("Closing the import window must not open the result") }
        try await waitUntil { await service.downloadCount == 1 }
        model.endPresentation()
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.downloadRequested)
        try await waitUntil { await service.cancelledDownloads == 1 }
        XCTAssertNil(model.media)
    }

    @MainActor func testQuitWaitsForCleanupAfterImportWindowHasClosed() async throws {
        let service=ImportServiceSpy()
        await service.releaseLookup(); await service.holdCleanup()
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/one")!)
        model.download { _ in XCTFail("A closed import must not open a video") }
        try await waitUntil { await service.downloadCount == 1 }
        model.endPresentation()
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.hasPendingWork)
        try await waitUntil { await service.cancelledDownloads == 1 }
        var finished=false
        let quitting=Task { await model.cancelAndWait(); finished=true }
        await Task.yield()
        XCTAssertFalse(finished,"Quit must wait until subprocess and workspace cleanup finish")
        await service.releaseCleanup()
        await quitting.value
        XCTAssertTrue(finished)
        XCTAssertFalse(model.hasPendingWork)
    }

    @MainActor func testNativeImportWindowTitleCloseAndCommandReturnDuringLookup() async throws {
        let service=ImportServiceSpy()
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/one")!)
        try await waitUntil { await service.lookupCount == 1 }
        let parent=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        var closed=false
        let controller=URLImportWindowController(importer:model,parent:parent,open:{ _ in XCTFail("No download was requested") },onClose:{ closed=true })
        let window=try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title,"Import URL")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(50))
        let compact=window.frame
        let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,
            windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
        XCTAssertTrue(window.performKeyEquivalent(with:event))
        XCTAssertTrue(model.formatsVisible)
        try await waitUntil { window.frame.height > compact.height+100 }
        XCTAssertEqual(window.frame.width,compact.width,accuracy:1)
        XCTAssertEqual(window.frame.maxY,compact.maxY,accuracy:1,"The URL row must not move when formats are revealed")
        assertEqual(await service.lookupCount,1)
        window.performClose(nil)
        XCTAssertTrue(closed)
        XCTAssertFalse(model.busy)
        try await waitUntil { await service.cancelledLookups == 1 }
    }

    @MainActor func testEditorPresentsAndReopensTheNativeImportWindow() async throws {
        _=NSApplication.shared
        let editor=Editor()
        let host=NSHostingView(rootView:EditorView(editor:editor,playback:editor.playback))
        let parent=NSWindow(contentRect:NSRect(x:100,y:100,width:520,height:440),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed=false; parent.contentView=host
        defer { parent.contentView=nil; parent.close(); editor.prepareToQuit() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(100))
        for _ in 0..<2 {
            editor.showURLImporter()
            try await waitUntil { NSApp.windows.contains { $0.title == "Import URL" && $0.isVisible } }
            let window=try XCTUnwrap(NSApp.windows.first { $0.title == "Import URL" && $0.isVisible })
            XCTAssertEqual(window.frame.width,URLImportLayout.width,accuracy:1)
            window.performClose(nil)
            try await waitUntil { !editor.importPresented }
        }
    }

    @MainActor func testFailedLookupRefreshesOnceAndDownloadsWithUpdatedTools() async throws {
        let service=ImportServiceSpy()
        await service.releaseLookup(); await service.releaseDownload()
        await service.failLookups(1,canRefresh:true)
        let model=URLImport(service:service)
        model.urlText="https://example.com/one"
        model.showFormats(); model.selectVideo("137"); model.audio="none"
        var opened=false
        model.download { _ in opened=true }
        try await waitUntil { !model.busy }
        XCTAssertTrue(opened)
        XCTAssertNil(model.error)
        assertEqual(await service.lookupCount,2)
        assertEqual(await service.refreshCount,1)
        assertEqual(await service.selectors,["137"])
        assertEqual(await service.downloadedToolVersions,["updated"])
    }

    @MainActor func testFailedLookupDoesNotRetryRepeatedlyOrExposeBackgroundErrors() async throws {
        let service=ImportServiceSpy()
        await service.releaseLookup()
        await service.failLookups(3,canRefresh:true)
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/one")!)
        try await waitUntil { !model.busy }
        assertEqual(await service.lookupCount,2)
        assertEqual(await service.refreshCount,1)
        XCTAssertNil(model.error,"A passive prefetch must stay in the background even if it fails")
        model.download { _ in XCTFail("A failed lookup cannot open a video") }
        try await waitUntil { !model.busy }
        XCTAssertTrue(model.error?.contains("Extractor failed") == true)
        assertEqual(await service.lookupCount,3)
        assertEqual(await service.downloadCount,0)
    }

    @MainActor func testReturnDoesNotDownloadWhileInputMethodIsComposing() async throws {
        let service=ImportServiceSpy()
        let model=URLImport(service:service)
        model.urlText="https://example.com/one"
        let parent=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed=false
        let controller=URLImportWindowController(importer:model,parent:parent,open:{ _ in XCTFail("Composing text must not download") },onClose:{})
        defer { controller.close(); parent.close() }
        let window=try XCTUnwrap(controller.window)
        let text=NSTextView()
        window.contentView=text
        XCTAssertTrue(window.makeFirstResponder(text))
        text.setMarkedText("あ",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertTrue(text.hasMarkedText())
        for modifiers:NSEvent.ModifierFlags in [[],.command] {
            let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,
                windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
            XCTAssertFalse(window.performKeyEquivalent(with:event))
            XCTAssertFalse(model.downloadRequested)
            XCTAssertFalse(model.formatsVisible)
        }
        assertEqual(await service.lookupCount,0)
    }

    @MainActor func testNativeReturnDownloadsTheSelectedFormats() async throws {
        let service=ImportServiceSpy()
        await service.releaseLookup(); await service.releaseDownload()
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/one")!)
        try await waitUntil { !model.busy }
        model.showFormats(); model.selectVideo("137"); model.audio="none"
        let parent=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed=false
        var opened=false
        let controller=URLImportWindowController(importer:model,parent:parent,open:{ _ in opened=true },onClose:{})
        defer { controller.close(); parent.close() }
        let window=try XCTUnwrap(controller.window)
        let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,
            windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
        XCTAssertTrue(window.performKeyEquivalent(with:event))
        try await waitUntil { opened }
        assertEqual(await service.selectors,["137"])
        assertEqual(await service.excludedAudio,[true])
    }

    @MainActor func testRangeIntentSurvivesPendingLookupAndDefaultsToFull() async throws {
        let service=ImportServiceSpy()
        await service.releaseDownload()
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/one?t=90")!)
        model.rangeEnabled=true; model.rangeStart="08:00"; model.rangeEnd="08:30"
        var opened=false
        model.download { _ in opened=true }
        model.rangeStart="1"; model.rangeEnd="2"; model.rangeEnabled=false
        await service.releaseLookup()
        try await waitUntil { opened }
        assertEqual(await service.ranges,[try ImportRange(start:480,end:510)])
        model.begin(url:URL(string:"https://example.com/two?t=90")!)
        opened=false
        model.download { _ in opened=true }
        try await waitUntil { opened }
        assertEqual(await service.ranges,[try ImportRange(start:480,end:510),nil])
    }

    @MainActor func testRangeIntentSurvivesLookupToolRefresh() async throws {
        let service=ImportServiceSpy(duration:100)
        await service.releaseLookup(); await service.releaseDownload()
        await service.failLookups(1,canRefresh:true)
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/video")!)
        model.rangeEnabled=true; model.rangeStart="10"; model.rangeEnd="20"
        var opened=false
        model.download { _ in opened=true }
        try await waitUntil { opened }
        assertEqual(await service.lookupCount,2)
        assertEqual(await service.refreshCount,1)
        assertEqual(await service.downloadedToolVersions,["updated"])
        assertEqual(await service.ranges,[try ImportRange(start:10,end:20)])
        XCTAssertNil(model.error)
    }

    @MainActor func testRangeRevalidatesWhenDurationArrives() async throws {
        let service=ImportServiceSpy(duration:100)
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/video")!)
        model.rangeEnabled=true; model.rangeStart="90"; model.rangeEnd="110"
        model.download { _ in XCTFail("Out-of-bounds range must not open") }
        await service.releaseLookup()
        try await waitUntil { !model.busy }
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.canRetryFull)
        assertEqual(await service.downloadCount,0)
    }
    @MainActor func testRangeFailureOffersExplicitFullRetry() async throws {
        let service=ImportServiceSpy(failRange:true)
        await service.releaseLookup(); await service.releaseDownload()
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/video")!)
        model.rangeEnabled=true; model.rangeStart="10"; model.rangeEnd="20"
        var opened=false
        model.download { _ in opened=true }
        try await waitUntil { !model.busy }
        XCTAssertFalse(opened); XCTAssertTrue(model.canRetryFull)
        assertEqual(await service.downloadCount,1)
        model.retryFull { _ in opened=true }
        try await waitUntil { opened }
        XCTAssertFalse(model.rangeEnabled)
        assertEqual(await service.ranges,[try ImportRange(start:10,end:20),nil])
    }

    @MainActor func testImportWindowGrowsToFitRangeControls() async throws {
        _=NSApplication.shared
        let service=ImportServiceSpy(duration:600)
        await service.releaseLookup()
        let model=URLImport(service:service)
        model.begin(url:URL(string:"https://example.com/video")!)
        try await waitUntil { !model.busy }
        let parent=NSWindow(contentRect:NSRect(x:100,y:100,width:1100,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed=false
        let controller=URLImportWindowController(importer:model,parent:parent,open:{ _ in },onClose:{})
        defer { controller.close(); parent.close() }
        controller.showWindow(nil)
        let window=try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(50))
        let compact=window.frame.height
        model.rangeEnabled=true; model.rangeStart="08:00"; model.rangeEnd="08:30"
        try await waitUntil { window.frame.height > compact+60 }
        let content=try XCTUnwrap(window.contentView)
        XCTAssertGreaterThanOrEqual(content.bounds.height,content.fittingSize.height-1)
        XCTAssertEqual(window.frame.width,URLImportLayout.width,accuracy:1)
    }

    @MainActor private func waitUntil(_ condition:() async -> Bool) async throws {
        let deadline=Date().addingTimeInterval(3)
        while !(await condition()) {
            guard Date() < deadline else { XCTFail("Timed out waiting for importer"); return }
            try await Task.sleep(for:.milliseconds(10))
        }
    }
}

private actor ImportServiceSpy:URLImportServicing {
    private let duration:Double?
    private let failRange:Bool
    init(duration:Double?=nil,failRange:Bool=false) { self.duration=duration; self.failRange=failRange }
    private var lookupReleased=false
    private var downloadReleased=false
    private var cleanupHeld=false
    private var cleanupContinuation:CheckedContinuation<Void,Never>?
    private var failedLookups=0
    private var canRefresh=false
    private(set) var refreshCount=0
    private(set) var downloadedToolVersions=[String]()
    private(set) var lookupCount=0
    private(set) var downloadCount=0
    private(set) var cancelledLookups=0
    private(set) var cancelledDownloads=0
    private(set) var selectors=[String]()
    private(set) var excludedAudio=[Bool]()
    private(set) var downloadURLs=[URL]()
    private(set) var ranges=[ImportRange?]()
    func releaseLookup() { lookupReleased=true }
    func releaseDownload() { downloadReleased=true }
    func holdCleanup() { cleanupHeld=true }
    func releaseCleanup() { cleanupHeld=false; cleanupContinuation?.resume(); cleanupContinuation=nil }
    func failLookups(_ count:Int,canRefresh:Bool) { failedLookups=count; self.canRefresh=canRefresh }
    func prepare(status:@escaping @Sendable(String)->Void) async throws -> ImportTools {
        let executable=URL(fileURLWithPath:"/usr/bin/true")
        return ImportTools(ytDLP:executable,deno:executable,ffmpegDirectory:executable.deletingLastPathComponent(),version:"test",notice:nil)
    }
    func refreshAfterFailure(status:@escaping @Sendable(String)->Void) async throws -> ImportTools? {
        refreshCount += 1
        guard canRefresh else { return nil }
        canRefresh=false
        let tools=try await prepare(status:status)
        return ImportTools(ytDLP:tools.ytDLP,deno:tools.deno,ffmpegDirectory:tools.ffmpegDirectory,version:"updated",notice:nil)
    }
    func inspect(url:URL,tools:ImportTools) async throws -> URLMedia {
        lookupCount += 1
        do { while !lookupReleased { try await Task.sleep(for:.milliseconds(10)) }; try Task.checkCancellation() }
        catch { cancelledLookups += 1; throw error }
        if failedLookups > 0 { failedLookups -= 1; throw ImportFailure.message("Extractor failed") }
        var json:[String:Any]=["id":url.absoluteString,"title":"Example","formats":[
            ["format_id":"18","vcodec":"h264","acodec":"aac"],
            ["format_id":"137","vcodec":"h264","acodec":"none"],
            ["format_id":"140","vcodec":"none","acodec":"aac"]]]
        if let duration { json["duration"]=duration }
        return try URLMedia.decode(JSONSerialization.data(withJSONObject:json))
    }
    func download(url:URL,media:URLMedia,selector:String,excludeAudio:Bool,range:ImportRange?,tools:ImportTools,
                  progress:@escaping @Sendable(ImportProgress)->Void) async throws -> TemporaryImport {
        downloadCount += 1; ranges.append(range); selectors.append(selector); excludedAudio.append(excludeAudio); downloadURLs.append(url)
        downloadedToolVersions.append(tools.version)
        do { while !downloadReleased { try await Task.sleep(for:.milliseconds(10)) }; try Task.checkCancellation() }
        catch {
            cancelledDownloads += 1
            if cleanupHeld { await withCheckedContinuation { cleanupContinuation=$0 } }
            throw error
        }
        if failRange && range != nil { throw ImportFailure.message("This format cannot be partially downloaded.") }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file=directory.appendingPathComponent("Example.mp4")
        try Data("test".utf8).write(to:file)
        return TemporaryImport(directory:directory,file:file)
    }
}
