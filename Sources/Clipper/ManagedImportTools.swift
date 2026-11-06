import Foundation
import CryptoKit

/// Resolved, verified tools for one URL import. Paths stay valid until the next `prepare`.
struct ImportTools: Sendable {
    let ytDLP: URL
    let deno: URL
    let ffmpegDirectory: URL
    let version: String
    let notice: String?
}

/// Installs yt-dlp and Deno into Application Support/Clipper/Tools.
///
/// Trust model (v1): release metadata comes from the official GitHub API over HTTPS, and each payload must match the
/// SHA-256 digest that GitHub publishes for that release asset. This detects corruption and tampering in transit or
/// on a mirror, but it is not independent signature verification: a compromised GitHub release would be trusted.
/// Nothing is executed until it matches the digest, is a Mach-O for this Mac, and reports the expected version.
actor ManagedImportTools {
    static let shared=ManagedImportTools()

    typealias Fetch=@Sendable (_ url:URL, _ limit:Int, _ destination:URL) async throws -> Void
    typealias Run=@Sendable (_ executable:URL, _ arguments:[String]) async throws -> String

    private let root:URL
    private let now:@Sendable () -> Date
    private let fetch:Fetch
    private let run:Run
    private let ffmpeg:@Sendable () -> URL?
    private let cpuType:UInt32
    private var tail:Task<Void,Never>?
    static let checkInterval:TimeInterval=24*60*60

    init(root:URL=ManagedImportTools.defaultRoot, now:@escaping @Sendable () -> Date={ Date() },
         fetch:@escaping Fetch=ManagedImportTools.download, run:@escaping Run=ManagedImportTools.smokeTest,
         ffmpeg:@escaping @Sendable () -> URL?={ ManagedImportTools.bundledFFmpegDirectory() },
         cpuType:UInt32=ManagedImportTools.hostCPUType) {
        self.root=root; self.now=now; self.fetch=fetch; self.run=run; self.ffmpeg=ffmpeg; self.cpuType=cpuType
    }

    /// Serialized across callers: a second caller waits for the first to finish (and then normally hits the
    /// daily throttle). Cancelling one caller cancels only its own work.
    func prepare(force:Bool=false, status:@escaping @Sendable (String)->Void) async throws -> ImportTools {
        let previous=tail
        let work=Task { [self] in
            await previous?.value
            try Task.checkCancellation()
            return try await perform(force:force, status:status)
        }
        tail=Task { _=try? await work.value }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    // MARK: - Update flow

    private func perform(force:Bool, status:@escaping @Sendable (String)->Void) async throws -> ImportTools {
        guard let ffmpegDirectory=ffmpeg() else {
            throw ImportFailure.message("The bundled media engine is missing. Rebuild Clipper with scripts/build-app.sh.")
        }
        try FileManager.default.createDirectory(at:root, withIntermediateDirectories:true)
        clearStaging()
        var manifest=loadManifest()
        let installed=Tool.allCases.allSatisfy { isInstalled($0, manifest) }
        let current=now()
        if installed, !force, let checked=manifest.checked, checked <= current, current.timeIntervalSince(checked) < Self.checkInterval {
            return tools(manifest, ffmpegDirectory, notice:nil)
        }
        var problems:[String]=[]
        for tool in Tool.allCases {
            do {
                try await update(tool, &manifest, status:status)
            } catch {
                if Self.isCancellation(error) { clearStaging(); throw CancellationError() }
                let detail=(error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                guard let version=isInstalled(tool, manifest) ? manifest.tools[tool.rawValue]?.current : nil else {
                    throw ImportFailure.message("Clipper needs to download \(tool.title) once before importing from a URL, but it could not: \(detail)")
                }
                problems.append("Could not update \(tool.title) (\(detail)). Using \(version).")
            }
        }
        try Task.checkCancellation()
        manifest.checked=current
        try saveManifest(manifest)
        return tools(manifest, ffmpegDirectory, notice:problems.isEmpty ? nil : problems.joined(separator:" "))
    }

    private func update(_ tool:Tool, _ manifest:inout Manifest, status:@escaping @Sendable (String)->Void) async throws {
        status("Checking for \(tool.title) updates…")
        let release=try await latestRelease(tool)
        let entry=manifest.tools[tool.rawValue]
        if entry?.current == release.version, isInstalled(tool, manifest) { return }

        let staging=root.appendingPathComponent(".staging/\(UUID().uuidString)", isDirectory:true)
        let output=staging.appendingPathComponent("out", isDirectory:true)
        defer { try? FileManager.default.removeItem(at:staging) }
        try FileManager.default.createDirectory(at:output, withIntermediateDirectories:true)
        let payload=staging.appendingPathComponent("payload")
        status("Downloading \(tool.title) \(release.version)…")
        try await fetch(release.url, release.size, payload)
        try Task.checkCancellation()

        status("Verifying \(tool.title) \(release.version)…")
        let size=(try FileManager.default.attributesOfItem(atPath:payload.path)[.size] as? NSNumber)?.intValue
        guard size == release.size else { throw ImportFailure.message("the download was incomplete") }
        guard try Self.sha256(of:payload) == release.sha256 else { throw ImportFailure.message("the download failed its SHA-256 checksum") }

        let binary=output.appendingPathComponent(tool.binary)
        switch tool {
        case .ytDLP:
            try FileManager.default.moveItem(at:payload, to:binary)
        case .deno:
            let unzipped=staging.appendingPathComponent("unzipped", isDirectory:true)
            try FileManager.default.createDirectory(at:unzipped, withIntermediateDirectories:true)
            _=try await Self.withTimeout(120) {
                try await ImportProcess().run(executable:URL(fileURLWithPath:"/usr/bin/ditto"),
                                              arguments:["-x","-k","--norsrc",payload.path,unzipped.path], outputLimit:64*1024)
            }
            let contents=try FileManager.default.contentsOfDirectory(atPath:unzipped.path)
            let extracted=unzipped.appendingPathComponent("deno")
            guard contents == ["deno"],
                  (try FileManager.default.attributesOfItem(atPath:extracted.path)[.type] as? FileAttributeType) == .typeRegular
            else { throw ImportFailure.message("the Deno archive had unexpected contents") }
            try FileManager.default.moveItem(at:extracted, to:binary)
        }
        guard try Self.machO(binary, contains:cpuType) else { throw ImportFailure.message("the download is not a program for this Mac") }
        try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath:binary.path)
        let reported=try await Self.withTimeout(60) { [run] in try await run(binary, ["--version"]) }
        guard tool.matches(reported, release.version) else { throw ImportFailure.message("the downloaded program reported an unexpected version") }
        try Task.checkCancellation()

        // Commit: move the verified directory into place, then atomically switch the manifest.
        let destination=directory(tool, release.version)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(), withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:destination.path) { try FileManager.default.removeItem(at:destination) }
        try FileManager.default.moveItem(at:output, to:destination)
        let previous=entry.flatMap { $0.current == release.version ? $0.previous : $0.current }
        manifest.tools[tool.rawValue]=Manifest.Entry(current:release.version, previous:previous)
        try saveManifest(manifest)
        prune(tool, keep:[release.version, previous].compactMap { $0 })
    }

    private func latestRelease(_ tool:Tool) async throws -> Release {
        let file=root.appendingPathComponent(".staging/\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(), withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:file) }
        try await fetch(URL(string:"https://api.github.com/repos/\(tool.repository)/releases/latest")!, 2*1024*1024, file)
        let info=try JSONDecoder().decode(GitHubRelease.self, from:Data(contentsOf:file))
        let version=tool == .deno && info.tag_name.hasPrefix("v") ? String(info.tag_name.dropFirst()) : info.tag_name
        guard !info.draft, !info.prerelease, Self.safeVersion(version) else { throw ImportFailure.message("GitHub returned an unexpected release") }
        let name=tool.asset(cpuType)
        guard let asset=info.assets.first(where:{ $0.name == name }),
              let url=URL(string:asset.browser_download_url), Self.officialAsset(url, tool),
              asset.size > 0, asset.size <= 512*1024*1024
        else { throw ImportFailure.message("the release does not include \(name)") }
        var digest=asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        if digest == nil, let sums=info.assets.first(where:{ $0.name == tool.checksumAsset(name) }),
           let sumsURL=URL(string:sums.browser_download_url), Self.officialAsset(sumsURL, tool) {
            let list=root.appendingPathComponent(".staging/\(UUID().uuidString).sums")
            defer { try? FileManager.default.removeItem(at:list) }
            try await fetch(sumsURL, 256*1024, list)
            digest=Self.checksum(in:String(decoding:try Data(contentsOf:list), as:UTF8.self), for:name)
        }
        guard let digest, digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
            throw ImportFailure.message("GitHub did not publish a SHA-256 checksum for \(name)")
        }
        return Release(version:version, url:url, size:asset.size, sha256:digest)
    }

    // MARK: - Storage

    private func tools(_ manifest:Manifest, _ ffmpegDirectory:URL, notice:String?) -> ImportTools {
        let yt=manifest.tools[Tool.ytDLP.rawValue]!.current, deno=manifest.tools[Tool.deno.rawValue]!.current
        return ImportTools(ytDLP:directory(.ytDLP, yt).appendingPathComponent(Tool.ytDLP.binary),
                           deno:directory(.deno, deno).appendingPathComponent(Tool.deno.binary),
                           ffmpegDirectory:ffmpegDirectory, version:"yt-dlp \(yt) · Deno \(deno)", notice:notice)
    }

    private func directory(_ tool:Tool, _ version:String) -> URL {
        root.appendingPathComponent(tool.rawValue, isDirectory:true).appendingPathComponent(version, isDirectory:true)
    }

    private func isInstalled(_ tool:Tool, _ manifest:Manifest) -> Bool {
        guard let version=manifest.tools[tool.rawValue]?.current, Self.safeVersion(version) else { return false }
        return FileManager.default.isExecutableFile(atPath:directory(tool, version).appendingPathComponent(tool.binary).path)
    }

    private var manifestURL:URL { root.appendingPathComponent("manifest.json") }

    private func loadManifest() -> Manifest {
        guard let data=try? Data(contentsOf:manifestURL), var manifest=try? JSONDecoder().decode(Manifest.self, from:data) else { return Manifest() }
        manifest.tools=manifest.tools.filter { Tool(rawValue:$0.key) != nil && Self.safeVersion($0.value.current) }
        for (key, entry) in manifest.tools where !(entry.previous.map(Self.safeVersion) ?? true) { manifest.tools[key]?.previous=nil }
        return manifest
    }

    private func saveManifest(_ manifest:Manifest) throws {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(manifest).write(to:manifestURL, options:.atomic)
    }

    /// Keeps only the active and previous version; never removes a version the manifest references.
    private func prune(_ tool:Tool, keep:[String]) {
        let parent=root.appendingPathComponent(tool.rawValue, isDirectory:true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath:parent.path)) ?? [] where !keep.contains(name) {
            try? FileManager.default.removeItem(at:parent.appendingPathComponent(name))
        }
    }

    private func clearStaging() { try? FileManager.default.removeItem(at:root.appendingPathComponent(".staging")) }

    // MARK: - Verification helpers

    static func sha256(of file:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:file)
        defer { try? handle.close() }
        var hash=SHA256()
        while let chunk=try handle.read(upToCount:1<<20), !chunk.isEmpty { hash.update(data:chunk) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }

    /// True for a 64-bit thin Mach-O or universal binary that contains a slice for `cpuType`.
    static func machO(_ file:URL, contains cpuType:UInt32) throws -> Bool {
        let handle=try FileHandle(forReadingFrom:file)
        defer { try? handle.close() }
        let header=[UInt8](try handle.read(upToCount:4096) ?? Data())
        func big(_ at:Int) -> UInt32? { at+4 <= header.count ? header[at..<at+4].reduce(0) { $0<<8 | UInt32($1) } : nil }
        func little(_ at:Int) -> UInt32? { big(at).map { $0.byteSwapped } }
        switch big(0) {
        case 0xCFFAEDFE: return little(4) == cpuType
        case 0xCAFEBABE, 0xCAFEBABF:
            let stride=big(0) == 0xCAFEBABE ? 20 : 32
            guard let count=big(4), (1...16).contains(count) else { return false }
            return (0..<Int(count)).contains { big(8+$0*stride) == cpuType }
        default: return false
        }
    }

    static func checksum(in list:String, for name:String) -> String? {
        for line in list.split(whereSeparator:\.isNewline) {
            let fields=line.split(whereSeparator:\.isWhitespace)
            if fields.count == 1 { return String(fields[0]).lowercased() }
            if fields.count == 2, fields[1].trimmingCharacters(in:CharacterSet(charactersIn:"*")) == name { return String(fields[0]).lowercased() }
        }
        return nil
    }

    static func safeVersion(_ version:String) -> Bool {
        !version.isEmpty && version.count <= 64 && !version.hasPrefix(".")
            && version.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || ".-_+".unicodeScalars.contains($0) }
    }

    static func officialAsset(_ url:URL, _ tool:Tool) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/\(tool.repository)/releases/download/")
    }

    static func isCancellation(_ error:Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    static func withTimeout<T:Sendable>(_ seconds:Double, _ operation:@escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of:T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))
                throw ImportFailure.message("the program did not respond in time")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: - Production defaults

    static var defaultRoot:URL {
        let support=FileManager.default.urls(for:.applicationSupportDirectory, in:.userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Clipper/Tools", isDirectory:true)
    }

    static var hostCPUType:UInt32 {
        #if arch(arm64)
        return 0x0100000C
        #else
        return 0x01000007
        #endif
    }

    static func bundledFFmpegDirectory() -> URL? {
        let manager=FileManager.default
        let candidates=[Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory:true),
                        URL(fileURLWithPath:manager.currentDirectoryPath).appendingPathComponent(".build/media/bin", isDirectory:true)]
        return candidates.first { dir in
            ["ffmpeg","ffprobe"].allSatisfy { manager.isExecutableFile(atPath:dir.appendingPathComponent($0).path) }
        }
    }

    private static let session:URLSession = {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest=30
        configuration.timeoutIntervalForResource=15*60
        configuration.httpCookieStorage=nil
        configuration.urlCache=nil
        configuration.httpAdditionalHeaders=["User-Agent":"Clipper"]
        return URLSession(configuration:configuration)
    }()

    private static func trustedHost(_ url:URL?) -> Bool {
        guard let url, url.scheme == "https", let host=url.host?.lowercased() else { return false }
        return ["api.github.com","github.com"].contains(host) || host.hasSuffix(".githubusercontent.com")
    }

    static let download:Fetch = { url, limit, destination in
        guard trustedHost(url) else { throw ImportFailure.message("refused to download from \(url.host ?? "an unknown host")") }
        var request=URLRequest(url:url)
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField:"Accept")
            request.setValue("2022-11-28", forHTTPHeaderField:"X-GitHub-Api-Version")
        }
        let (file, response)=try await session.download(for:request)
        defer { try? FileManager.default.removeItem(at:file) }
        guard let http=response as? HTTPURLResponse, trustedHost(http.url) else { throw ImportFailure.message("GitHub redirected to an unexpected host") }
        switch http.statusCode {
        case 200: break
        case 403, 429: throw ImportFailure.message("GitHub’s download limit was reached; try again later")
        default: throw ImportFailure.message("GitHub returned HTTP \(http.statusCode)")
        }
        let size=(try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue ?? .max
        guard size <= limit else { throw ImportFailure.message("the download was larger than expected") }
        try? FileManager.default.removeItem(at:destination)
        try FileManager.default.moveItem(at:file, to:destination)
    }

    static let smokeTest:Run = { executable, arguments in
        let environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "LANG":"en_US.UTF-8", "HOME":FileManager.default.homeDirectoryForCurrentUser.path,
                         "TMPDIR":NSTemporaryDirectory(), "DENO_NO_UPDATE_CHECK":"1", "NO_COLOR":"1"]
        let data=try await ImportProcess().run(executable:executable, arguments:arguments, environment:environment, outputLimit:64*1024)
        return String(decoding:data, as:UTF8.self)
    }
}

extension ManagedImportTools {
    enum Tool:String, CaseIterable, Sendable {
        case ytDLP="yt-dlp", deno="deno"
        var title:String { self == .ytDLP ? "yt-dlp" : "Deno" }
        var repository:String { self == .ytDLP ? "yt-dlp/yt-dlp" : "denoland/deno" }
        var binary:String { rawValue }
        func asset(_ cpuType:UInt32) -> String {
            self == .ytDLP ? "yt-dlp_macos" : cpuType == 0x01000007 ? "deno-x86_64-apple-darwin.zip" : "deno-aarch64-apple-darwin.zip"
        }
        func checksumAsset(_ asset:String) -> String { self == .ytDLP ? "SHA2-256SUMS" : asset+".sha256sum" }
        func matches(_ output:String, _ version:String) -> Bool {
            let first=output.split(whereSeparator:\.isNewline).first.map { $0.trimmingCharacters(in:.whitespaces) } ?? ""
            return self == .ytDLP ? first == version : first == "deno \(version)" || first.hasPrefix("deno \(version) ")
        }
    }

    struct Release { let version:String; let url:URL; let size:Int; let sha256:String }

    struct Manifest:Codable {
        struct Entry:Codable { var current:String; var previous:String? }
        var tools:[String:Entry]=[:]
        var checked:Date?
    }

    private struct GitHubRelease:Decodable {
        struct Asset:Decodable { let name:String; let size:Int; let digest:String?; let browser_download_url:String }
        let tag_name:String
        let draft:Bool
        let prerelease:Bool
        let assets:[Asset]
    }
}
