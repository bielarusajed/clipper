import XCTest
@testable import Clipper

final class ExportPreferencesTests:XCTestCase {
    private var suite:String!
    private var defaults:UserDefaults!
    private var root:URL!
    private var downloads:URL!
    private var preferences:ExportPreferences!

    override func setUpWithError() throws {
        suite="app.clipper.tests.export-preferences.\(UUID().uuidString)"
        defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/export-preferences-tests/\(UUID().uuidString)",isDirectory:true)
        downloads=root.appendingPathComponent("Downloads",isDirectory:true)
        try FileManager.default.createDirectory(at:downloads,withIntermediateDirectories:true)
        preferences=ExportPreferences(defaults:defaults,downloadsDirectory:downloads)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName:suite)
        // TemporaryImport can remove its child directory on the decode queue
        // while teardown recursively removes the private test root.
        try? FileManager.default.removeItem(at:root)
        preferences=nil; defaults=nil
    }

    func testDefaultsAndReadingDoesNotWritePreferences() {
        XCTAssertEqual(preferences.makeSettings(),EditSettings())
        XCTAssertEqual(preferences.resolvedSaveDirectory(),downloads)
        XCTAssertTrue(defaults.persistentDomain(forName:suite)?.isEmpty ?? true)
    }

    func testChoicesSurviveNewPreferencesInstance() throws {
        preferences.setCodec(.hevc); preferences.setQuality(81.7)
        preferences.recordSaveDirectory(from:root.appendingPathComponent("clip.mp4"))
        let reopened=ExportPreferences(defaults:try XCTUnwrap(UserDefaults(suiteName:suite)),downloadsDirectory:downloads)
        XCTAssertEqual(reopened.codec,.hevc)
        XCTAssertEqual(reopened.quality,82)
        XCTAssertEqual(reopened.resolvedSaveDirectory(),root)
        XCTAssertEqual(defaults.string(forKey:ExportPreferences.Key.codec),"hevc")
        XCTAssertEqual(defaults.persistentDomain(forName:suite)?.count,3,"Only codec, quality and folder are persisted")
    }

    func testCorruptPreferencesFallBackWithoutRewritingThem() {
        for value:Any in ["future-codec",42,["hevc"]] {
            defaults.set(value,forKey:ExportPreferences.Key.codec)
            XCTAssertEqual(preferences.codec,.h264)
        }
        for value:Any in [Double.nan,Double.infinity,5.0,200.0,"80",true,[65]] {
            defaults.set(value,forKey:ExportPreferences.Key.quality)
            XCTAssertEqual(preferences.quality,65,"Invalid quality: \(value)")
        }
        for value in [20.0,65,95] {
            preferences.setQuality(value)
            XCTAssertEqual(preferences.quality,value)
        }
        preferences.setQuality(.nan); preferences.setQuality(96)
        XCTAssertEqual(preferences.quality,95)
        defaults.set("future-codec",forKey:ExportPreferences.Key.codec)
        _=preferences.makeSettings()
        XCTAssertEqual(defaults.string(forKey:ExportPreferences.Key.codec),"future-codec")
    }

    func testStaleInvalidAndUnavailableDirectoriesFallBack() throws {
        let folder=root.appendingPathComponent("Chosen",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        preferences.recordSaveDirectory(from:folder.appendingPathComponent("clip.mp4"))
        XCTAssertEqual(preferences.resolvedSaveDirectory(),folder)
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:folder.path)
        XCTAssertEqual(preferences.resolvedSaveDirectory(),downloads)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
        try FileManager.default.removeItem(at:folder)
        XCTAssertEqual(preferences.resolvedSaveDirectory(),downloads)
        XCTAssertEqual(defaults.string(forKey:ExportPreferences.Key.saveDirectory),folder.path,"A temporarily unavailable drive is not forgotten")
        // A file at the remembered path is not a usable directory.
        try Data().write(to:folder)
        XCTAssertEqual(preferences.resolvedSaveDirectory(),downloads)
        for invalid:Any in ["","relative/folder","https://example.com",12,["folder"]] {
            defaults.set(invalid,forKey:ExportPreferences.Key.saveDirectory)
            XCTAssertEqual(preferences.resolvedSaveDirectory(),downloads)
        }
        try FileManager.default.removeItem(at:downloads)
        XCTAssertEqual(preferences.resolvedSaveDirectory(),FileManager.default.homeDirectoryForCurrentUser)
    }

    @MainActor func testHDRNormalizationDoesNotReplaceSDRPreference() async throws {
        let editor=Editor(preferences:preferences)
        defer { editor.close() }
        editor.setCodec(.h264); editor.setQuality(83)
        editor.open(fixture("hdr.mp4"))
        try await waitUntil { editor.canExport }
        XCTAssertEqual(editor.edit.codec,.hevc)
        XCTAssertEqual(preferences.codec,.h264)
        XCTAssertEqual(editor.edit.quality,83)
        // The disabled HDR picker must not turn HEVC into a user preference.
        editor.setCodec(.hevc)
        XCTAssertEqual(preferences.codec,.h264)
        editor.setConvertToSDR(true)
        XCTAssertEqual(editor.edit.codec,.h264)
        XCTAssertTrue(editor.edit.convertToSDR)
        editor.setConvertToSDR(false)
        XCTAssertEqual(editor.edit.codec,.hevc)
        XCTAssertEqual(preferences.codec,.h264)
        // Also exercise the existing normalization safety net.
        let previous=editor.edit
        editor.edit.codec = .h264
        editor.settingsChanged(previous)
        XCTAssertEqual(editor.edit.codec,.hevc)
        XCTAssertEqual(preferences.codec,.h264)
        editor.open(fixture("cfr.mp4"))
        try await waitUntil { editor.canExport }
        XCTAssertEqual(editor.edit.codec,.h264)
        XCTAssertEqual(editor.edit.quality,83)
        XCTAssertFalse(editor.edit.convertToSDR)
        editor.close()
        XCTAssertEqual(editor.edit,preferences.makeSettings())
    }

    @MainActor func testExplicitChoicesPersistAndPerVideoSettingsReset() async throws {
        let editor=Editor(preferences:preferences)
        defer { editor.close() }
        editor.open(fixture("hdr.mp4"))
        try await waitUntil { editor.canExport }
        editor.setConvertToSDR(true)
        editor.setCodec(.hevc); editor.setQuality(91)
        editor.setConvertToSDR(false); editor.setConvertToSDR(true)
        XCTAssertEqual(editor.edit.codec,.hevc,"An explicit codec choice during SDR conversion is remembered")
        editor.edit.cropPreset = .square
        editor.edit.crop=CGRect(x:0.1,y:0.1,width:0.5,height:0.5)
        editor.edit.resolution = .tiny
        editor.edit.muted=true; editor.edit.audioTrack=5
        editor.open(fixture("cfr.mp4"))
        try await waitUntil { editor.canExport }
        XCTAssertEqual(editor.edit,preferences.makeSettings())
        XCTAssertEqual(editor.edit.codec,.hevc)
        XCTAssertEqual(editor.edit.quality,91)
        XCTAssertEqual(editor.inTime,0,accuracy:0.001)
        XCTAssertEqual(editor.outTime,6,accuracy:0.001)
        editor.close()
        let reopened=Editor(preferences:ExportPreferences(defaults:try XCTUnwrap(UserDefaults(suiteName:suite)),downloadsDirectory:downloads))
        reopened.open(fixture("cfr.mp4"))
        defer { reopened.close() }
        try await waitUntil { reopened.canExport }
        XCTAssertEqual(reopened.edit.codec,.hevc)
        XCTAssertEqual(reopened.edit.quality,91)
    }

    @MainActor func testLocalOneClickExportStaysBesideSourceAndDoesNotRecordAFolder() async throws {
        let local=root.appendingPathComponent("Local",isDirectory:true)
        try FileManager.default.createDirectory(at:local,withIntermediateDirectories:true)
        let source=local.appendingPathComponent("Source.mp4")
        try FileManager.default.copyItem(at:fixture("cfr.mp4"),to:source)
        let original=try Data(contentsOf:source)
        preferences.recordSaveDirectory(from:root.appendingPathComponent("chosen.mp4"))
        let editor=Editor(preferences:preferences)
        defer { editor.close() }
        editor.open(source)
        try await waitUntil { editor.canExport }
        let existing=local.appendingPathComponent("Source-clip.mp4")
        try Data("existing output".utf8).write(to:existing)
        let expected=local.appendingPathComponent("Source-clip-2.mp4")
        XCTAssertEqual(editor.uniqueOutput(for:source),expected)
        editor.markEnd(0.99)
        try await waitUntil { !editor.playback.seeking }
        editor.export()
        try await waitUntil { !editor.exporting }
        XCTAssertNil(editor.error)
        XCTAssertEqual(editor.lastExport,expected)
        XCTAssertGreaterThan(try Data(contentsOf:expected).count,100)
        XCTAssertEqual(try Data(contentsOf:source),original)
        XCTAssertEqual(try Data(contentsOf:existing),Data("existing output".utf8))
        XCTAssertEqual(editor.nextOutputURL,local.appendingPathComponent("Source-clip-3.mp4"))
        XCTAssertEqual(preferences.resolvedSaveDirectory(),root)
        XCTAssertEqual(defaults.persistentDomain(forName:suite)?.count,1,"Export and load must not write normalized settings")
    }

    @MainActor func testImportedSourceAndSaveAsUseRememberedFolderAndUniqueNames() async throws {
        let directory=root.appendingPathComponent("Import",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let source=directory.appendingPathComponent("Imported.mp4")
        try FileManager.default.copyItem(at:fixture("cfr.mp4"),to:source)
        let saved=root.appendingPathComponent("Saved",isDirectory:true)
        try FileManager.default.createDirectory(at:saved,withIntermediateDirectories:true)
        preferences.recordSaveDirectory(from:saved.appendingPathComponent("previous.mp4"))
        try Data().write(to:saved.appendingPathComponent("Imported-clip.mp4"))
        let editor=Editor(preferences:preferences)
        defer { editor.close() }
        editor.open(source,temporary:TemporaryImport(directory:directory,file:source))
        try await waitUntil { editor.canExport }
        XCTAssertEqual(editor.nextOutputURL,saved.appendingPathComponent("Imported-clip-2.mp4"))
        XCTAssertEqual(editor.uniqueOutput(for:source,in:preferences.resolvedSaveDirectory()),editor.nextOutputURL)
        // Losing the folder falls back on the next request rather than using a stale path.
        try FileManager.default.removeItem(at:saved)
        XCTAssertEqual(editor.uniqueOutput(for:source).deletingLastPathComponent(),downloads)
    }

    private func fixture(_ name:String) -> URL {
        URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/fixtures/\(name)")
    }
    @MainActor private func waitUntil(_ condition:() -> Bool) async throws {
        let deadline=Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(condition(),"Editor did not finish the operation")
        if !condition() { throw ExportFailure.message("Timed out waiting for editor") }
    }
}
