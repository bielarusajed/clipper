import XCTest
import CMedia
@testable import Clipper

final class URLImportTests:XCTestCase {
    private func media(_ extra:String="") throws -> URLMedia {
        try JSONDecoder().decode(URLMedia.self,from:Data("""
        {"id":"test","title":"Example",\(extra)"formats":[
          {"format_id":"18","ext":"mp4","vcodec":"avc1","acodec":"aac","height":360},
          {"format_id":"137","ext":"mp4","vcodec":"avc1","acodec":"none","height":1080},
          {"format_id":"140","ext":"m4a","vcodec":"none","acodec":"aac","language":"en"},
          {"format_id":"141","ext":"m4a","vcodec":"none","acodec":"aac","language":"pl"},
          {"format_id":"drm","vcodec":"h264","acodec":"none","has_drm":true},
          {"format_id":"unsafe+selector","vcodec":"h264","acodec":"none"}]}
        """.utf8))
    }

    func testFormatSelectionKeepsResolutionAndAudioChoice() throws {
        let info=try media()
        try info.validate()
        XCTAssertEqual(info.videos.map(\.id),["137","18"])
        XCTAssertEqual(info.audios.map(\.id),["141","140"])
        XCTAssertEqual(try info.selector(video:"best",audio:"best"),"bv+ba/b")
        XCTAssertEqual(try info.selector(video:"137",audio:"141"),"137+141")
        XCTAssertEqual(try info.selector(video:"137",audio:"none"),"137")
        XCTAssertEqual(try info.selector(video:"best",audio:"none"),"bv/b")
        XCTAssertEqual(try info.selector(video:"best",audio:"141"),"bv+141")
        XCTAssertEqual(try info.selector(video:"18",audio:"140"),"18")
        XCTAssertThrowsError(try info.selector(video:"unsafe+selector",audio:"best"))
        XCTAssertThrowsError(try info.selector(video:"best",audio:"missing"))
        XCTAssertThrowsError(try info.selector(video:"none",audio:"best"))
    }

    func testRejectsPlaylistsAndLiveStreams() throws {
        for extra in ["\"_type\":\"playlist\",","\"is_live\":true,","\"live_status\":\"is_upcoming\","] {
            XCTAssertThrowsError(try media(extra).validate())
        }
        XCTAssertNoThrow(try media("\"live_status\":\"post_live\",").validate())
        let audioOnly=try URLMedia.decode(Data("{\"id\":\"audio\",\"title\":\"Audio\",\"formats\":[{\"format_id\":\"a\",\"vcodec\":\"none\",\"acodec\":\"aac\"}]}".utf8))
        XCTAssertThrowsError(try audioOnly.validate())
    }

    @MainActor func testFormatTableRequiresVideoAndCanRestoreIncludedAudio() throws {
        let rows=ImportFormatRow.rows(try media())
        XCTAssertEqual(rows.prefix(2).map(\.id),["best","none"])
        XCTAssertFalse(rows.contains(where:{ $0.kind == .format && $0.id == "drm" }))
        let model=URLImport()
        model.selectVideo("137")
        model.audio="none"
        XCTAssertEqual(model.video,"137")
        model.begin()
        XCTAssertEqual(model.video,"best"); XCTAssertEqual(model.audio,"best")
        XCTAssertFalse(model.formatsVisible)
    }

    func testProgressSupportsUnknownSizesAndSeparateStreamProgress() throws {
        let known=ImportProgress.parse("CLIPPER_PROGRESS:{\"downloaded_bytes\":25,\"total_bytes\":100,\"speed\":1000}")
        XCTAssertEqual(known?.fraction,0.25)
        XCTAssertTrue(known?.label.contains("current stream") == true)
        XCTAssertNil(ImportProgress.parse("CLIPPER_PROGRESS:{\"downloaded_bytes\":25,\"total_bytes\":null}")?.fraction)
        XCTAssertNil(ImportProgress.parse("CLIPPER_PROGRESS:not json"))
        XCTAssertNil(ImportProgress.parse("unrelated log line"))
        XCTAssertNil(ImportProgress.parse("CLIPPER_POST:started")?.fraction)
    }

    func testCompletedFileCannotEscapeStagingAndPublicationNeverOverwrites() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let staging=root.appendingPathComponent("staging",isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source=staging.appendingPathComponent("source.mkv")
        let outside=root.appendingPathComponent("outside.mkv")
        try Data("video".utf8).write(to:source)
        try Data("existing".utf8).write(to:outside)
        func report(_ file:URL) throws -> Data {
            Data("CLIPPER_FILE:".utf8)+(try JSONEncoder().encode(file.path))+Data("\n".utf8)
        }
        XCTAssertEqual(try URLMediaDownload.completedFile(output:report(source),workspace:staging),source)
        XCTAssertThrowsError(try URLMediaDownload.completedFile(output:report(outside),workspace:staging))
        let link=staging.appendingPathComponent("link.mkv")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        XCTAssertThrowsError(try URLMediaDownload.completedFile(output:report(link),workspace:staging))
        let published=try URLMediaDownload.publish(file:"outside",source:source,destination:root)
        XCTAssertEqual(published.lastPathComponent,"outside-2.mkv")
        XCTAssertEqual(try Data(contentsOf:outside),Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf:published),Data("video".utf8))
    }

    func testURLValidationAndSafeNames() throws {
        XCTAssertEqual(try URLMedia.parseURL(" https://example.com/watch?v=1 ").host,"example.com")
        for input in ["file:///tmp/a.mp4","--exec=bad","example.com","https://user:password@example.com/a"] {
            XCTAssertThrowsError(try URLMedia.parseURL(input))
        }
        XCTAssertEqual(URLMedia.filename(title:"../a/b:\\c\n"),"a b  c")
        XCTAssertEqual(URLMedia.filename(title:"..."),"Imported video")
        XCTAssertLessThanOrEqual(URLMedia.filename(title:String(repeating:"🎬",count:150)).utf8.count,180)
    }

    func testProcessDrainsBothPipesAndHandlesCancellation() async throws {
        let echo=ImportProcess()
        let data=try await echo.run(executable:URL(fileURLWithPath:"/usr/bin/printf"),arguments:["%s","a literal $(command) with spaces"])
        XCTAssertEqual(String(decoding:data,as:UTF8.self),"a literal $(command) with spaces")
        let job=ImportProcess()
        let task=Task { try await job.run(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["30"]) }
        try await Task.sleep(for:.milliseconds(100))
        task.cancel()
        do { _=try await task.value; XCTFail("Cancellation must fail the job") }
        catch is CancellationError { }
    }

    func testCancellationBeforeLaunchAndOutputLimit() async throws {
        let job=ImportProcess()
        job.cancel()
        do { _=try await job.run(executable:URL(fileURLWithPath:"/usr/bin/true"),arguments:[]); XCTFail("A cancelled job must not start") }
        catch is CancellationError { }
        do {
            _=try await ImportProcess().run(executable:URL(fileURLWithPath:"/usr/bin/printf"),arguments:["123456789"],outputLimit:4)
            XCTFail("Large metadata must fail without unbounded memory")
        } catch is ImportFailure { }
    }

    func testFailedProcessReportsItsOwnDiagnostics() async throws {
        do {
            _=try await ImportProcess().run(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","echo 'expected tool error' >&2; exit 1"])
            XCTFail("A failed tool must throw")
        } catch {
            XCTAssertEqual(error.localizedDescription,"expected tool error")
        }
    }

    func testCancellationStopsDescendantsAndDrainsLargePipes() async throws {
        // The shell is a test fixture only. Production tools always run without a shell.
        let job=ImportProcess()
        let started=expectation(description:"child started")
        let task=Task {
            try await job.run(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","sleep 30 & echo ready; wait"]) { line in
                if line == "ready" { started.fulfill() }
            }
        }
        await fulfillment(of:[started],timeout:3)
        let beginning=Date()
        task.cancel()
        do { _=try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(beginning),5,"A descendant holding stdout open must also be cancelled")
        let output=try await ImportProcess().run(executable:URL(fileURLWithPath:"/bin/sh"),
            arguments:["-c","/usr/bin/head -c 100000 /dev/zero >&2 & /usr/bin/head -c 100000 /dev/zero; wait"])
        XCTAssertEqual(output.count,100000)
    }

    func testBundledFFmpegMergesDownloadedCodecsForEditor() async throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let engine=root.appendingPathComponent(".build/media/bin/ffmpeg")
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        for fixture in ["cfr.mp4","vp9.webm","av1.webm"] {
            let output=directory.appendingPathComponent(fixture+".mkv")
            _=try await ImportProcess().run(executable:engine,arguments:["-v","error","-nostdin","-i",root.appendingPathComponent(".build/fixtures/"+fixture).path,
                "-i",root.appendingPathComponent(".build/fixtures/"+(fixture == "cfr.mp4" ? "cfr.mp4" : "vp9.webm")).path,
                "-map","0:v:0","-map","1:a:0","-c","copy",output.path])
            var message=[CChar](repeating:0,count:512)
            let decoder=clip_open(output.path,0,&message,512)
            XCTAssertNotNil(decoder,"\(fixture) should open after stream-copy merge")
            if let decoder {
                XCTAssertEqual(clip_info(decoder).audioCount,1)
                let frame=clip_frame(decoder,0.5)
                XCTAssertEqual(frame.kind,1); frame.sample?.release()
                clip_close(decoder)
            }
        }
    }

    func testDownloadPipelinePublishesAndCleansFailures() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let fixture=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/fixtures/cfr.mp4")
        let stub=root.appendingPathComponent("fake-downloader")
        // Fixed test-only script: copy a real fixture and emit yt-dlp's final-path protocol.
        let script="""
        #!/bin/sh
        /bin/cp '\(fixture.path)' source.mp4
        printf 'CLIPPER_FILE:"%s/source.mp4"\\n' "$PWD"
        """
        try Data(script.utf8).write(to:stub)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:stub.path)
        let tools=ImportTools(ytDLP:stub,deno:URL(fileURLWithPath:"/usr/bin/true"),
            ffmpegDirectory:ManagedImportTools.bundledFFmpegDirectory()!,version:"test",notice:nil)
        let destination=root.appendingPathComponent("Downloads",isDirectory:true)
        let info=try media()
        let url=URL(string:"https://example.com/video")!
        var imported:TemporaryImport?=try await URLMediaDownload.download(url:url,media:info,selector:"137+140",
            tools:tools,temporaryRoot:destination) { _ in }
        let output=try XCTUnwrap(imported?.file)
        XCTAssertEqual(output.lastPathComponent,"Example.mp4")
        XCTAssertEqual(try Data(contentsOf:output),try Data(contentsOf:fixture))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:destination.path).count,1)
        imported=nil
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:destination.path),[])

        let silent=try await URLMediaDownload.download(url:url,media:info,selector:"18",excludeAudio:true,
            tools:tools,temporaryRoot:destination) { _ in }
        var message=[CChar](repeating:0,count:512)
        let decoder=clip_open(silent.file.path,0,&message,512)
        XCTAssertNotNil(decoder)
        if let decoder { XCTAssertEqual(clip_info(decoder).audioCount,0); clip_close(decoder) }
        silent.dispose()

        try Data("#!/bin/sh\necho 'test failure' >&2\nexit 1\n".utf8).write(to:stub)
        do {
            _=try await URLMediaDownload.download(url:url,media:info,selector:"137",
                tools:tools,temporaryRoot:destination) { _ in }
            XCTFail("A failed download must not publish")
        } catch { XCTAssertEqual(error.localizedDescription,"test failure") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:destination.path),[])
    }

    @MainActor func testTemporarySourceDisposesOnCloseReplacementAndQuit() async throws {
        let files=FileManager.default
        let fixture=URL(fileURLWithPath:files.currentDirectoryPath).appendingPathComponent(".build/fixtures/cfr.mp4")
        for action in ["close","replace","quit"] {
            let directory=files.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
            try files.createDirectory(at:directory,withIntermediateDirectories:true)
            let source=directory.appendingPathComponent("Downloaded.mp4")
            try files.copyItem(at:fixture,to:source)
            var owner:TemporaryImport?=TemporaryImport(directory:directory,file:source)
            let editor=Editor()
            editor.open(source,temporary:owner)
            owner=nil
            XCTAssertTrue(files.fileExists(atPath:source.path),"Editor must retain the imported source")
            XCTAssertEqual(editor.nextOutputURL?.deletingLastPathComponent(),files.urls(for:.downloadsDirectory,in:.userDomainMask).first)
            switch action {
            case "replace": editor.open(fixture)
            case "quit": editor.prepareToQuit()
            default: editor.close()
            }
            await withCheckedContinuation { continuation in editor.playback.queue.async { continuation.resume() } }
            XCTAssertFalse(files.fileExists(atPath:directory.path),"\(action) must dispose the source directory")
            XCTAssertTrue(files.fileExists(atPath:fixture.path),"Local source files must be preserved")
            editor.close()
        }
    }

    @MainActor func testExportOutlivesDisposableSource() async throws {
        let files=FileManager.default
        let root=files.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let directory=root.appendingPathComponent("import",isDirectory:true)
        try files.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? files.removeItem(at:root) }
        let fixture=URL(fileURLWithPath:files.currentDirectoryPath).appendingPathComponent(".build/fixtures/cfr.mp4")
        let source=directory.appendingPathComponent("Source.mp4"), output=root.appendingPathComponent("Export.mp4")
        try files.copyItem(at:fixture,to:source)
        let editor=Editor()
        editor.open(source,temporary:TemporaryImport(directory:directory,file:source))
        let deadline=Date().addingTimeInterval(10)
        while !editor.canExport && Date() < deadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(editor.canExport)
        editor.export(to:output,replacingExisting:false)
        while editor.exporting && Date() < deadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertNil(editor.error)
        XCTAssertTrue(files.fileExists(atPath:output.path))
        editor.close()
        await withCheckedContinuation { continuation in editor.playback.queue.async { continuation.resume() } }
        XCTAssertFalse(files.fileExists(atPath:directory.path))
        XCTAssertTrue(files.fileExists(atPath:output.path),"Exports must survive source disposal")
    }

    func testLiveManagedInstallAndURLDownload() async throws {
        guard ProcessInfo.processInfo.environment["CLIPPER_NETWORK_TEST"] == "1" else { throw XCTSkip("Opt-in official-tool/network integration test") }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/url-import-integration",isDirectory:true)
        let manager=ManagedImportTools(root:root.appendingPathComponent("Tools",isDirectory:true))
        let tools=try await manager.prepare { print($0) }
        let url=try URLMedia.parseURL("https://download.blender.org/peach/trailer/trailer_iphone.m4v")
        let media=try await URLMediaDownload.inspect(url:url,tools:tools)
        XCTAssertFalse(media.videos.isEmpty)
        let selector=try media.selector(video:"best",audio:"best")
        let updates=ImportProgressRecorder()
        let imported=try await URLMediaDownload.download(url:url,media:media,selector:selector,
            tools:tools,temporaryRoot:root.appendingPathComponent("Imports",isDirectory:true)) { updates.record($0) }
        let file=imported.file
        XCTAssertTrue(updates.sawDownload,"Progress must still be enabled when printing the final filename")
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        var message=[CChar](repeating:0,count:512)
        let decoder=clip_open(file.path,0,&message,512)
        XCTAssertNotNil(decoder)
        if let decoder { let frame=clip_frame(decoder,0.5); XCTAssertEqual(frame.kind,1); frame.sample?.release(); clip_close(decoder) }
    }
}

private final class ImportProgressRecorder:@unchecked Sendable {
    private let lock=NSLock()
    private var downloading=false
    func record(_ update:ImportProgress) { lock.withLock { if update.label.hasPrefix("Downloading") { downloading=true } } }
    var sawDownload:Bool { lock.withLock { downloading } }
}
