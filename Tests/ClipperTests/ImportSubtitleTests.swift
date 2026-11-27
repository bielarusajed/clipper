import XCTest
import CMedia
@testable import Clipper

final class ImportSubtitleTests:XCTestCase {
    let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)

    func testCatalogListsTextLanguagesSkipsTranslationsAndLeadsWithPreferred() throws {
        let info=try URLMedia.decode(Data("""
        {"id":"t","title":"T","formats":[{"format_id":"18","vcodec":"avc1","acodec":"aac"}],
         "subtitles":{"en":[{"ext":"json3"},{"ext":"vtt","name":"English"}],"live_chat":[{"ext":"json"}],
                      "-bad":[{"ext":"vtt"}],"x,y":[{"ext":"vtt"}],"pl":"broken","de":[{"ext":"srt","name":"Deutsch"}]},
         "automatic_captions":{"en":[{"ext":"vtt","name":"English"}],"ja-orig":[{"ext":"vtt","name":"Japanese (Original)"}],
                               "fr":[{"ext":"vtt","name":"French"},7]}}
        """.utf8))
        XCTAssertEqual(info.subtitleOptions(preferredLanguages:[]).map(\.id),["de","en","auto:ja-orig"])
        XCTAssertEqual(info.subtitleOptions(preferredLanguages:["ja-JP","en-GB"]).map(\.id),["auto:ja-orig","en","de"])
        let japanese=info.subtitleOptions(preferredLanguages:[])[2]
        XCTAssertEqual(japanese.label,"Japanese (Original) (auto-generated)")
        XCTAssertEqual(japanese.pattern,"ja-orig")
        XCTAssertEqual(URLSubtitle(language:"zh.Hans",name:"",kind:.authored).pattern,#"zh\.Hans"#)
        let noOriginal=try URLMedia.decode(Data(#"{"id":"t","title":"T","formats":[],"automatic_captions":{"fr":[{"ext":"vtt","name":"French"}]}}"#.utf8))
        XCTAssertEqual(noOriginal.subtitleOptions(preferredLanguages:[]).map(\.id),["auto:fr"])
        let plain=try URLMedia.decode(Data(#"{"id":"t","title":"T","formats":[],"subtitles":null,"automatic_captions":[]}"#.utf8))
        XCTAssertEqual(plain.subtitleOptions(),[])
    }

    @MainActor func testSubtitleChoiceIsRemembered() throws {
        let defaults=try XCTUnwrap(UserDefaults(suiteName:"ImportSubtitleTests-\(UUID())"))
        XCTAssertFalse(URLImport(defaults:defaults).subtitlesEnabled)
        URLImport(defaults:defaults).subtitlesEnabled=true
        let importer=URLImport(defaults:defaults)
        XCTAssertTrue(importer.subtitlesEnabled)
        importer.resetLookup()
        XCTAssertTrue(importer.subtitlesEnabled)
    }

    @MainActor func testURLTimestampOnlyPrefillsAnEnabledRange() async throws {
        let importer=URLImport(service:TimestampService(),defaults:try XCTUnwrap(UserDefaults(suiteName:"ImportSubtitleTests-\(UUID())")))
        importer.begin(url:URL(string:"https://example.com/watch?t=90")!)
        let deadline=Date().addingTimeInterval(3)
        while importer.media == nil && Date() < deadline { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(importer.rangeEnabled)
        XCTAssertEqual([importer.rangeStart,importer.rangeEnd],["0",""])
        importer.rangeEnabled=true; importer.rangeToggled()
        XCTAssertEqual([importer.rangeStart,importer.rangeEnd],[TimeText.format(90),TimeText.format(100)])
        importer.rangeStart="10"; importer.rangeEnabled=false; importer.rangeEnabled=true; importer.rangeToggled()
        XCTAssertEqual(importer.rangeStart,"10","Typed times are never replaced")
    }

    func testShiftMovesCuesAndDropsThoseBeforeTheSection() throws {
        let vtt="WEBVTT\r\n\r\nNOTE kept\r\n\r\n00:01.000 --> 00:02.000\r\ngone\r\n\r\n00:09.500 --> 00:11.000 align:start\r\n<c>spans</c><00:10.500>late\r\n\r\n01:00:12.000 --> 01:00:13.250\r\nhour"
        XCTAssertEqual(SubtitleShift.shift(vtt,format:"vtt",by:-10),
            "WEBVTT\n\nNOTE kept\n\n00:00:00.000 --> 00:00:01.000 align:start\n<c>spans</c><00:00:00.500>late\n\n01:00:02.000 --> 01:00:03.250\nhour")
        let srt="1\n00:00:01,000 --> 00:00:02,000\ngone\n\n2\n00:00:11,500 --> 00:00:12,000\nkept\n"
        XCTAssertEqual(SubtitleShift.shift(srt,format:"srt",by:-10),"2\n00:00:01,500 --> 00:00:02,000\nkept\n")
        XCTAssertEqual(SubtitleShift.shift(srt,format:"srt",by:0.25),"1\n00:00:01,250 --> 00:00:02,250\ngone\n\n2\n00:00:11,750 --> 00:00:12,250\nkept\n")
        XCTAssertNil(SubtitleShift.shift(srt,format:"srt",by:-60))
        let ass="[Script Info]\nTitle: x\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,gone\nDialogue: 0,0:00:10.50,0:00:12.00,Default,,0,0,0,,a, b"
        XCTAssertEqual(SubtitleShift.shift(ass,format:"ass",by:-10),
            "[Script Info]\nTitle: x\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.50,0:00:02.00,Default,,0,0,0,,a, b")
    }

    func testCollectKeepsRequestedOrderAndTextFormats() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        for name in ["s.en.vtt","s.de.srt","s.fr.json3","s.pl.vtt"] { try Data(name == "s.pl.vtt" ? [] : Array("x".utf8)).write(to:dir.appendingPathComponent(name)) }
        let wanted=["de","en","fr","pl"].map { URLSubtitle(language:$0,name:$0,kind:.authored) }
        XCTAssertEqual(ImportSubtitles.collect(directory:dir,subtitles:wanted.reversed()).map(\.file.lastPathComponent),["s.en.vtt","s.de.srt"])
    }

    /// Imported captions become ordinary container tracks, aligned to a ranged import's local clock.
    func testMuxedSubtitlesAppearAsContainerTracks() async throws {
        let source=root.appendingPathComponent(".build/fixtures/offset.mkv")
        let ffmpeg=root.appendingPathComponent(".build/media/bin/ffmpeg")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:source.path),"Run scripts/make-fixtures.sh")
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let vtt=dir.appendingPathComponent("s.en.vtt"), srt=dir.appendingPathComponent("s.de.srt")
        try "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nbefore\n\n00:00:12.000 --> 00:00:13.000\ninside\n".write(to:vtt,atomically:true,encoding:.utf8)
        try "1\n00:00:14,000 --> 00:00:15,000\nzwei\n".write(to:srt,atomically:true,encoding:.utf8)
        let items=[ImportedSubtitle(subtitle:URLSubtitle(language:"en",name:"English",kind:.automatic),file:vtt),
                   ImportedSubtitle(subtitle:URLSubtitle(language:"de",name:"Deutsch",kind:.authored),file:srt)]
        let result=try await ImportSubtitles.mux(file:source,subtitles:items,shift:-10,existingSubtitleStreams:0,workspace:dir,ffmpeg:ffmpeg)
        let muxed=try XCTUnwrap(result)
        let catalog=try XCTUnwrap(clip_subtitle_catalog(muxed.path,nil)); defer { clip_subtitle_catalog_free(catalog) }
        XCTAssertEqual(clip_subtitle_count(catalog),2)
        XCTAssertEqual(String(cString:clip_subtitle_label(catalog,0)),"1. en / English (auto-generated) (webvtt)")
        XCTAssertEqual(String(cString:clip_subtitle_label(catalog,1)),"2. de / Deutsch (subrip)")
        var error=[CChar](repeating:0,count:512)
        let before=try XCTUnwrap(clip_open(source.path,-1,&error,512)); let original=clip_info(before); clip_close(before)
        let after=try XCTUnwrap(clip_open(muxed.path,-1,&error,512)); defer { clip_close(after) }
        XCTAssertEqual(clip_info(after).origin,original.origin,accuracy:0.001,"Video timestamps must not move")
        let ass=dir.appendingPathComponent("out.ass")
        try SubtitleProcess().run(["-copyts","-i",muxed.path,"-map","0:s:0","-c:s","ass","-f","ass",ass.path],directory:dir)
        let dialogue=try String(contentsOf:ass,encoding:.utf8).components(separatedBy:"\n").filter { $0.hasPrefix("Dialogue:") }
        XCTAssertEqual(dialogue,["Dialogue: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,inside"])
    }

    func testLiveRangedImportEmbedsSubtitles() async throws {
        guard ProcessInfo.processInfo.environment["CLIPPER_SUBTITLE_NETWORK_TEST"] == "1" else { throw XCTSkip("Opt-in YouTube subtitle import test") }
        let manager=ManagedImportTools(root:root.appendingPathComponent(".build/url-import-integration/Tools",isDirectory:true))
        let tools=try await manager.prepare { print($0) }
        let url=try URLMedia.parseURL("https://www.youtube.com/watch?v=eRsGyueVLvQ")
        let media=try await URLMediaDownload.inspect(url:url,tools:tools)
        let options=media.subtitleOptions(preferredLanguages:["en"])
        XCTAssertEqual(options.first?.id,"en")
        let imported=try await URLMediaDownload.download(url:url,media:media,selector:media.selector(video:"best",audio:"best"),
            range:ImportRange(start:120,end:135),subtitles:options,tools:tools,
            temporaryRoot:root.appendingPathComponent(".build/url-import-integration/Imports",isDirectory:true)) { print($0.label) }
        let catalog=try XCTUnwrap(clip_subtitle_catalog(imported.file.path,nil)); defer { clip_subtitle_catalog_free(catalog) }
        XCTAssertGreaterThan(clip_subtitle_count(catalog),1)
        print(options.count,"offered,",clip_subtitle_count(catalog),"embedded; first:",String(cString:clip_subtitle_label(catalog,0)))
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }
        let ass=dir.appendingPathComponent("out.ass")
        try SubtitleProcess().run(["-copyts","-i",imported.file.path,"-map","0:s:0","-c:s","ass","-f","ass",ass.path],directory:dir)
        let text=try String(contentsOf:ass,encoding:.utf8)
        print(text.components(separatedBy:"\n").filter { $0.hasPrefix("Dialogue:") }.prefix(4).joined(separator:"\n"))
        XCTAssertTrue(text.contains("Dialogue:"))
    }
}

private struct TimestampService:URLImportServicing {
    func prepare(status:@escaping @Sendable(String)->Void) async throws -> ImportTools {
        let tool=URL(fileURLWithPath:"/usr/bin/true")
        return ImportTools(ytDLP:tool,deno:tool,ffmpegDirectory:tool.deletingLastPathComponent(),version:"test",notice:nil)
    }
    func refreshAfterFailure(status:@escaping @Sendable(String)->Void) async throws -> ImportTools? { nil }
    func inspect(url:URL,tools:ImportTools) async throws -> URLMedia {
        try URLMedia.decode(Data(#"{"id":"t","title":"T","duration":100,"start_time":90,"formats":[{"format_id":"18","vcodec":"avc1","acodec":"aac"}]}"#.utf8))
    }
    func download(url:URL,media:URLMedia,selector:String,excludeAudio:Bool,range:ImportRange?,subtitles:[URLSubtitle],tools:ImportTools,
                  progress:@escaping @Sendable(ImportProgress)->Void) async throws -> TemporaryImport { throw CancellationError() }
}
