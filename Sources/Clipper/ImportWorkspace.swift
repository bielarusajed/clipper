import Foundation
import Darwin

/// A lease keeps launch-time cleanup from deleting another running import's files.
final class ImportWorkspace:@unchecked Sendable {
    static var root:URL { FileManager.default.temporaryDirectory.appendingPathComponent("Clipper/Imports",isDirectory:true) }
    private static let leaseName=".owner.lock"
    let directory:URL
    private let descriptor:Int32
    private let lock=NSLock()
    private var disposed=false

    init(root:URL=ImportWorkspace.root) throws {
        let files=FileManager.default
        try files.createDirectory(at:root,withIntermediateDirectories:true)
        directory=root.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try files.createDirectory(at:directory,withIntermediateDirectories:false)
        descriptor=Darwin.open(directory.appendingPathComponent(Self.leaseName).path,O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC,0o600)
        guard descriptor >= 0 else {
            let code=errno
            try? files.removeItem(at:directory)
            throw POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)
        }
        guard flock(descriptor,LOCK_EX|LOCK_NB) == 0 else {
            let code=errno
            Darwin.close(descriptor); try? files.removeItem(at:directory)
            throw POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)
        }
    }

    func dispose() {
        lock.withLock {
            guard !disposed else { return }
            disposed=true
            try? FileManager.default.removeItem(at:directory)
            Darwin.close(descriptor)
        }
    }
    deinit { dispose() }

    static func removeAbandoned(root:URL=ImportWorkspace.root,now:Date=Date()) {
        let files=FileManager.default
        let keys:Set<URLResourceKey>=[.isDirectoryKey,.isSymbolicLinkKey,.contentModificationDateKey]
        guard let directories=try? files.contentsOfDirectory(at:root,includingPropertiesForKeys:Array(keys),options:.skipsHiddenFiles) else { return }
        for directory in directories {
            guard UUID(uuidString:directory.lastPathComponent) != nil,
                  let values=try? directory.resourceValues(forKeys:keys), values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let descriptor=Darwin.open(directory.appendingPathComponent(leaseName).path,O_RDWR|O_CLOEXEC|O_NOFOLLOW)
            if descriptor >= 0 {
                // A crashed process releases its lease automatically. Active imports keep theirs.
                if flock(descriptor,LOCK_EX|LOCK_NB) == 0 { try? files.removeItem(at:directory) }
                Darwin.close(descriptor)
            } else if errno == ENOENT, let modified=values.contentModificationDate, now.timeIntervalSince(modified) > 24*60*60 {
                // Older versions had no lease. Leave recent directories alone, including one being created.
                try? files.removeItem(at:directory)
            }
        }
    }
}
