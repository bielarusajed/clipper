import Foundation
import Darwin

enum ImportFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): return message } }
}

/// Each job owns a process group, so cancellation also stops FFmpeg and Deno.
final class ImportProcess: @unchecked Sendable {
    private let lock=NSLock()
    private var group:pid_t=0
    private var cancelled=false

    func cancel() {
        lock.withLock {
            cancelled=true
            if group > 0 { kill(-group,SIGINT) }
        }
        DispatchQueue.global().asyncAfter(deadline:.now()+2) { [self] in
            lock.withLock { if cancelled && group > 0 { kill(-group,SIGTERM) } }
        }
        DispatchQueue.global().asyncAfter(deadline:.now()+4) { [self] in
            lock.withLock { if cancelled && group > 0 { kill(-group,SIGKILL) } }
        }
    }

    static var environment:[String:String] {
        var result=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "LANG":"en_US.UTF-8", "LC_ALL":"en_US.UTF-8",
                    "HOME":FileManager.default.homeDirectoryForCurrentUser.path]
        for key in ["http_proxy","https_proxy","all_proxy","no_proxy","HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","NO_PROXY"] {
            result[key]=ProcessInfo.processInfo.environment[key]
        }
        return result
    }

    func run(executable:URL, arguments:[String], directory:URL?=nil,
             environment:[String:String]?=nil, outputLimit:Int=16*1024*1024, truncatingOutput:Bool=false,
             line:@escaping @Sendable (String)->Void={ _ in }) async throws -> Data {
        try await withTaskCancellationHandler {
            try await Task.detached(priority:.userInitiated) { [self] in
                try runBlocking(executable:executable,arguments:arguments,directory:directory,
                                environment:environment ?? Self.environment,outputLimit:outputLimit,truncatingOutput:truncatingOutput,line:line)
            }.value
        } onCancel: { self.cancel() }
    }

    private func runBlocking(executable:URL,arguments:[String],directory:URL?,environment:[String:String],
                             outputLimit:Int,truncatingOutput:Bool,line:@escaping @Sendable(String)->Void) throws -> Data {
        let output=Pipe(), errors=Pipe()
        var actions:posix_spawn_file_actions_t?, attributes:posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes,0)
        var mask=sigset_t(), defaults=sigset_t()
        sigemptyset(&mask); sigfillset(&defaults)
        posix_spawnattr_setsigmask(&attributes,&mask)
        posix_spawnattr_setsigdefault(&attributes,&defaults)
        posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0)
        posix_spawn_file_actions_adddup2(&actions,output.fileHandleForWriting.fileDescriptor,STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions,errors.fileHandleForWriting.fileDescriptor,STDERR_FILENO)
        for handle in [output.fileHandleForReading,output.fileHandleForWriting,errors.fileHandleForReading,errors.fileHandleForWriting] {
            posix_spawn_file_actions_addclose(&actions,handle.fileDescriptor)
        }
        if let directory { posix_spawn_file_actions_addchdir_np(&actions,directory.path) }
        let argv=([executable.path]+arguments).map { strdup($0) }+[nil]
        let env=environment.map { strdup("\($0.key)=\($0.value)") }+[nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid:pid_t=0
        try lock.withLock {
            if cancelled { throw CancellationError() }
            let result=argv.withUnsafeBufferPointer { args in
                env.withUnsafeBufferPointer { vars in
                    posix_spawn(&pid,executable.path,&actions,&attributes,
                                UnsafeMutablePointer(mutating:args.baseAddress!),UnsafeMutablePointer(mutating:vars.baseAddress!))
                }
            }
            guard result == 0 else { throw ImportFailure.message("Could not start \(executable.lastPathComponent): \(String(cString:strerror(result)))") }
            group=pid
        }
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()
        defer { output.fileHandleForReading.closeFile(); errors.fileHandleForReading.closeFile() }
        let drains=DispatchGroup()
        let captured=ImportCapture(limit:outputLimit), diagnostics=ImportCapture(limit:16000)
        drains.enter()
        DispatchQueue.global().async {
            var pending=Data()
            while true {
                let data=output.fileHandleForReading.availableData
                if data.isEmpty { break }
                captured.append(data); pending.append(data)
                while let newline=pending.firstIndex(of:10) {
                    line(String(decoding:pending[..<newline],as:UTF8.self))
                    pending.removeSubrange(...newline)
                }
                if pending.count > outputLimit { pending.removeAll() }
            }
            if !pending.isEmpty { line(String(decoding:pending,as:UTF8.self)) }
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global().async {
            while true {
                let data=errors.fileHandleForReading.availableData
                if data.isEmpty { break }
                diagnostics.append(data)
            }
            drains.leave()
        }
        var status:Int32=0
        while waitpid(pid,&status,0) == -1 && errno == EINTR { }
        drains.wait()
        let wasCancelled=lock.withLock { group=0; return cancelled }
        if wasCancelled { throw CancellationError() }
        guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else {
            let detail=String(decoding:diagnostics.data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            throw ImportFailure.message(detail.isEmpty ? "The download tool stopped unexpectedly." : detail)
        }
        guard truncatingOutput || !captured.overflow else { throw ImportFailure.message("The download tool returned too much metadata. Try a single video URL.") }
        return captured.data
    }
}

private final class ImportCapture: @unchecked Sendable {
    private let limit:Int
    private let lock=NSLock()
    private var bytes=Data()
    private var exceeded=false
    init(limit:Int) { self.limit=limit }
    func append(_ data:Data) {
        lock.withLock {
            bytes.append(data)
            if bytes.count > limit { exceeded=true; bytes=bytes.suffix(limit) }
        }
    }
    var data:Data { lock.withLock { bytes } }
    var overflow:Bool { lock.withLock { exceeded } }
}
