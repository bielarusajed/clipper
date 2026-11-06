import XCTest
import Foundation
@testable import Clipper

/// Offline fake of the GitHub API and release downloads.
private final class FakeGitHub:@unchecked Sendable {
    private let lock=NSLock()
    private var files:[URL:Data]=[:]
    private var blocked:Set<URL>=[]
    private(set) var requests:[URL]=[]
    var apiRequests:Int { lock.withLock { requests.filter { $0.host == "api.github.com" }.count } }

    func publish(_ repo:String, tag:String, asset:String, payload:Data, digest:String?=nil, extra:[(String,Data)]=[]) {
        let base="https://github.com/\(repo)/releases/download/\(tag)/"
        var assets:[[String:Any]]=[]
        lock.withLock {
            for (name,data) in [(asset,payload)]+extra {
                files[URL(string:base+name)!]=data
                var entry:[String:Any]=["name":name,"size":data.count,"browser_download_url":base+name]
                if name == asset, let digest { entry["digest"]=digest.isEmpty ? NSNull() : "sha256:"+digest }
                else if name == asset { entry["digest"]="sha256:"+hex(data) }
                assets.append(entry)
            }
            files[URL(string:"https://api.github.com/repos/\(repo)/releases/latest")!]=try! JSONSerialization.data(withJSONObject:
                ["tag_name":tag,"draft":false,"prerelease":false,"assets":assets])
        }
    }
    func block(_ url:String) { lock.withLock { _=blocked.insert(URL(string:url)!) } }

    var fetch:ManagedImportTools.Fetch {
        { [self] url, limit, destination in
            let (data,isBlocked)=lock.withLock { requests.append(url); return (files[url],blocked.contains(url)) }
            if isBlocked { try await Task.sleep(nanoseconds:60_000_000_000) }
            guard let data else { throw ImportFailure.message("HTTP 404") }
            guard data.count <= limit else { throw ImportFailure.message("too large") }
            try data.write(to:destination)
        }
    }
}

private func hex(_ data:Data) -> String {
    let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! data.write(to:file); defer { try? FileManager.default.removeItem(at:file) }
    return try! ManagedImportTools.sha256(of:file)
}

private final class Clock:@unchecked Sendable {
    private let lock=NSLock()
    private var value=Date(timeIntervalSince1970:1_800_000_000)
    var date:Date { lock.withLock { value } }
    func advance(hours:Double) { lock.withLock { value+=hours*3600 } }
}

final class ManagedImportToolsTests:XCTestCase {
    private var root:URL!
    private var github:FakeGitHub!
    private var clock:Clock!
    private let binary=try! Data(contentsOf:URL(fileURLWithPath:"/usr/bin/true"))
    private let ytDLP="https://github.com/yt-dlp/yt-dlp/releases/download/"

    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("ManagedImportTools-\(UUID().uuidString)")
        github=FakeGitHub(); clock=Clock()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }

    /// The fake smoke test reports the given versions, so a mismatched binary is detectable.
    private func tools(reported:[String:String]=[:]) -> ManagedImportTools {
        let clock=clock!
        let ffmpeg=root.appendingPathComponent("ffmpeg-bin")
        return ManagedImportTools(root:root, now:{ clock.date }, fetch:github.fetch, run:{ executable, _ in
            if executable.lastPathComponent == "yt-dlp" { return (reported["yt-dlp"] ?? "2026.10.26")+"\n" }
            return "deno \(reported["deno"] ?? "2.9.8") (stable, release, aarch64-apple-darwin)\nv8 14.0\n"
        }, ffmpeg:{ ffmpeg }, cpuType:0x0100000C)
    }

    private func denoZip(_ payload:Data) throws -> Data {
        let folder=root.appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
        try payload.write(to:folder.appendingPathComponent("deno"))
        let zip=root.appendingPathComponent("deno-\(UUID().uuidString).zip")
        let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        process.arguments=["-c","-k",folder.appendingPathComponent("deno").path,zip.path]
        try process.run(); process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at:zip); try? FileManager.default.removeItem(at:folder) }
        return try Data(contentsOf:zip)
    }

    private func publishBaseline(yt:String="2026.10.26", deno:String="v2.9.8") throws {
        github.publish("yt-dlp/yt-dlp", tag:yt, asset:"yt-dlp_macos", payload:binary)
        github.publish("denoland/deno", tag:deno, asset:"deno-aarch64-apple-darwin.zip", payload:try denoZip(binary))
    }

    private func manifest() throws -> [String:Any] {
        try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("manifest.json"))) as! [String:Any]
    }
    private func versions(_ tool:String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent(tool).path)) ?? []).sorted()
    }
    private func staging() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent(".staging").path)) ?? []
    }

    func testFirstInstallVerifiesAndCommits() async throws {
        try publishBaseline()
        let messages=Messages()
        let result=try await tools().prepare(status:{ messages.add($0) })
        XCTAssertEqual(result.version,"yt-dlp 2026.10.26 · Deno 2.9.8")
        XCTAssertNil(result.notice)
        XCTAssertEqual(result.ytDLP.path,root.appendingPathComponent("yt-dlp/2026.10.26/yt-dlp").path)
        XCTAssertEqual(result.deno.path,root.appendingPathComponent("deno/2.9.8/deno").path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:result.ytDLP.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:result.deno.path))
        XCTAssertEqual(try Data(contentsOf:result.deno),binary)
        XCTAssertEqual(result.ffmpegDirectory.lastPathComponent,"ffmpeg-bin")
        XCTAssertTrue(messages.all.contains("Downloading yt-dlp 2026.10.26…"))
        XCTAssertTrue(staging().isEmpty)
    }

    func testDailyThrottleAndForce() async throws {
        try publishBaseline()
        let manager=tools()
        _=try await manager.prepare(status:{ _ in })
        XCTAssertEqual(github.apiRequests,2)
        clock.advance(hours:23)
        _=try await manager.prepare(status:{ _ in })
        XCTAssertEqual(github.apiRequests,2,"Imports within a day must not contact GitHub")
        _=try await manager.prepare(force:true, status:{ _ in })
        XCTAssertEqual(github.apiRequests,4)
        let downloads=github.requests.filter { $0.host == "github.com" }.count
        XCTAssertEqual(downloads,2,"An unchanged version must not be downloaded again")
        clock.advance(hours:25)
        _=try await manager.prepare(status:{ _ in })
        XCTAssertEqual(github.apiRequests,6)
    }

    func testCorruptChecksumNeverInstalls() async throws {
        github.publish("yt-dlp/yt-dlp", tag:"2026.10.26", asset:"yt-dlp_macos", payload:binary, digest:String(repeating:"0", count:64))
        github.publish("denoland/deno", tag:"v2.9.8", asset:"deno-aarch64-apple-darwin.zip", payload:try denoZip(binary))
        do { _=try await tools().prepare(status:{ _ in }); XCTFail("A corrupt first install must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("SHA-256"), error.localizedDescription) }
        XCTAssertEqual(versions("yt-dlp"),[])
        XCTAssertTrue(staging().isEmpty)
    }

    func testFailedUpdateKeepsCurrentWithNotice() async throws {
        try publishBaseline()
        let manager=tools()
        _=try await manager.prepare(status:{ _ in })
        github.publish("yt-dlp/yt-dlp", tag:"2026.11.01", asset:"yt-dlp_macos", payload:binary, digest:String(repeating:"a", count:64))
        let result=try await manager.prepare(force:true, status:{ _ in })
        XCTAssertEqual(result.version,"yt-dlp 2026.10.26 · Deno 2.9.8")
        XCTAssertTrue(result.notice?.contains("Using 2026.10.26") == true, result.notice ?? "")
        XCTAssertEqual(versions("yt-dlp"),["2026.10.26"])
        XCTAssertEqual((try manifest()["tools"] as? [String:[String:String]])?["yt-dlp"]?["current"],"2026.10.26")
    }

    func testVersionMismatchAndForeignBinaryAreRejected() async throws {
        try publishBaseline()
        do { _=try await tools(reported:["yt-dlp":"2020.01.01"]).prepare(status:{ _ in }); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("unexpected version"), error.localizedDescription) }
        github.publish("yt-dlp/yt-dlp", tag:"2026.10.26", asset:"yt-dlp_macos", payload:Data("#!/bin/sh\necho 2026.10.26\n".utf8))
        do { _=try await tools().prepare(status:{ _ in }); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("not a program"), error.localizedDescription) }
        XCTAssertEqual(versions("yt-dlp"),[])
    }

    func testMissingDigestUsesPublishedChecksumFile() async throws {
        let sums=Data("\(hex(binary))  yt-dlp_macos\nffff  yt-dlp.exe\n".utf8)
        github.publish("yt-dlp/yt-dlp", tag:"2026.10.26", asset:"yt-dlp_macos", payload:binary, digest:"", extra:[("SHA2-256SUMS",sums)])
        github.publish("denoland/deno", tag:"v2.9.8", asset:"deno-aarch64-apple-darwin.zip", payload:try denoZip(binary))
        let result=try await tools().prepare(status:{ _ in })
        XCTAssertNil(result.notice)
    }

    func testCancelledUpdatePreservesCurrentAndDoesNotFallBack() async throws {
        try publishBaseline()
        let manager=tools()
        _=try await manager.prepare(status:{ _ in })
        github.publish("yt-dlp/yt-dlp", tag:"2026.11.01", asset:"yt-dlp_macos", payload:binary)
        github.block(ytDLP+"2026.11.01/yt-dlp_macos")
        let task=Task { try await manager.prepare(force:true, status:{ _ in }) }
        try await Task.sleep(nanoseconds:200_000_000)
        task.cancel()
        do { _=try await task.value; XCTFail("Cancellation must not fall back to the previous tools") }
        catch is CancellationError { }
        XCTAssertEqual(versions("yt-dlp"),["2026.10.26"])
        XCTAssertEqual((try manifest()["tools"] as? [String:[String:String]])?["yt-dlp"]?["current"],"2026.10.26")
        XCTAssertTrue(staging().isEmpty)
        // The actor stays usable after a cancelled caller.
        let after=try await manager.prepare(status:{ _ in })
        XCTAssertEqual(after.version,"yt-dlp 2026.10.26 · Deno 2.9.8")
    }

    func testUpdatesKeepOnlyCurrentAndPrevious() async throws {
        try publishBaseline()
        let manager=tools()
        _=try await manager.prepare(status:{ _ in })
        for tag in ["2026.11.01","2026.11.02"] {
            github.publish("yt-dlp/yt-dlp", tag:tag, asset:"yt-dlp_macos", payload:binary)
            let result=try await tools(reported:["yt-dlp":tag]).prepare(force:true, status:{ _ in })
            XCTAssertEqual(result.ytDLP.deletingLastPathComponent().lastPathComponent,tag)
        }
        XCTAssertEqual(versions("yt-dlp"),["2026.11.01","2026.11.02"])
        let entry=(try manifest()["tools"] as? [String:[String:String]])?["yt-dlp"]
        XCTAssertEqual(entry,["current":"2026.11.02","previous":"2026.11.01"])
    }

    func testConcurrentPreparesAreSerialized() async throws {
        try publishBaseline()
        let manager=tools()
        async let first=manager.prepare(status:{ _ in })
        async let second=manager.prepare(status:{ _ in })
        let results=try await [first,second]
        XCTAssertEqual(results.map(\.version),Array(repeating:"yt-dlp 2026.10.26 · Deno 2.9.8",count:2))
        XCTAssertEqual(github.apiRequests,2,"The second caller must reuse the first install")
    }

    func testMachOAndVersionValidation() throws {
        XCTAssertTrue(try ManagedImportTools.machO(URL(fileURLWithPath:"/usr/bin/true"), contains:0x0100000C))
        let script=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("#!/bin/sh\n".utf8).write(to:script); defer { try? FileManager.default.removeItem(at:script) }
        XCTAssertFalse(try ManagedImportTools.machO(script, contains:0x0100000C))
        for bad in ["","..","../x","a/b","2026 10"] { XCTAssertFalse(ManagedImportTools.safeVersion(bad), bad) }
        XCTAssertTrue(ManagedImportTools.safeVersion("2026.10.26"))
        XCTAssertFalse(ManagedImportTools.officialAsset(URL(string:"https://evil.example/yt-dlp/yt-dlp/releases/download/x")!, .ytDLP))
    }
}

private final class Messages:@unchecked Sendable {
    private let lock=NSLock(); private var items:[String]=[]
    func add(_ text:String) { lock.withLock { items.append(text) } }
    var all:[String] { lock.withLock { items } }
}

/// Opt-in end-to-end check against the real GitHub releases: CLIPPER_LIVE_TOOLS=1 scripts/test.sh --filter LiveImportTools
final class LiveImportToolsTests:XCTestCase {
    func testInstallsRealReleases() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLIPPER_LIVE_TOOLS"] == "1")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LiveImportTools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let result=try await ManagedImportTools(root:root, ffmpeg:{ root }).prepare(status:{ print($0) })
        print(result.version)
        XCTAssertNil(result.notice)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:result.ytDLP.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:result.deno.path))
    }
}
