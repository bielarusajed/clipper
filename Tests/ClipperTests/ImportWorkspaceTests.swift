import XCTest
@testable import Clipper

final class ImportWorkspaceTests:XCTestCase {
    func testCleanupRemovesAbandonedFilesAndPreservesActiveImports() throws {
        let files=FileManager.default
        let root=files.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? files.removeItem(at:root) }
        let active=try ImportWorkspace(root:root)
        let source=active.directory.appendingPathComponent("source.mp4")
        try Data("active video".utf8).write(to:source)
        let abandoned=root.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try files.createDirectory(at:abandoned,withIntermediateDirectories:false)
        try Data().write(to:abandoned.appendingPathComponent(".owner.lock"))
        try Data("partial download".utf8).write(to:abandoned.appendingPathComponent("source.part"))

        ImportWorkspace.removeAbandoned(root:root)
        XCTAssertFalse(files.fileExists(atPath:abandoned.path))
        XCTAssertEqual(try Data(contentsOf:source),Data("active video".utf8))
        // A downloaded source retains the lease after the download function returns.
        let imported=TemporaryImport(workspace:active,file:source)
        ImportWorkspace.removeAbandoned(root:root)
        XCTAssertTrue(files.fileExists(atPath:imported.file.path))
        imported.dispose()
        XCTAssertFalse(files.fileExists(atPath:active.directory.path))
    }

    func testCleanupBoundsLegacyFilesAndNeverFollowsSymlinks() throws {
        let files=FileManager.default
        let root=files.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let imports=root.appendingPathComponent("imports",isDirectory:true)
        let outside=root.appendingPathComponent("outside",isDirectory:true)
        try files.createDirectory(at:imports,withIntermediateDirectories:true)
        try files.createDirectory(at:outside,withIntermediateDirectories:true)
        defer { try? files.removeItem(at:root) }
        try Data().write(to:outside.appendingPathComponent(".owner.lock"))
        let recent=imports.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let old=imports.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let unrelated=imports.appendingPathComponent("unrelated",isDirectory:true)
        for directory in [recent,old,unrelated] { try files.createDirectory(at:directory,withIntermediateDirectories:false) }
        let now=Date()
        try files.setAttributes([.modificationDate:now.addingTimeInterval(-48*3600)],ofItemAtPath:old.path)
        try files.createSymbolicLink(at:imports.appendingPathComponent(UUID().uuidString),withDestinationURL:outside)

        ImportWorkspace.removeAbandoned(root:imports,now:now)
        XCTAssertFalse(files.fileExists(atPath:old.path))
        for directory in [recent,unrelated,outside] { XCTAssertTrue(files.fileExists(atPath:directory.path)) }
    }
}
