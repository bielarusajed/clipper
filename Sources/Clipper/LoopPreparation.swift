import Foundation
import CMedia

/// Owns the spare decoder exclusively until take() transfers it to the playback queue.
/// Cancelling only signals libav here; closing stays behind any decode on the prep queue.
final class LoopPreparation {
    private let queue=DispatchQueue(label:"clipper.loop.prepare",qos:.utility)
    private let lock=NSLock()
    private let request=clip_request_create()!
    private var epoch=0
    private var ready:OpaquePointer?
    private var key:String?

    deinit { if let ready { clip_close(ready) }; clip_request_free(request) }
    func prepare(url:URL,audioTrack:Int,start:Double,reusing:OpaquePointer?=nil) {
        let key="\(url.path)|\(audioTrack)|\(start)"
        let token:Int?=lock.withLock {
            if reusing == nil && self.key==key { return nil }
            self.key=key; epoch += 1; clip_request_set(request,Int32(truncatingIfNeeded:epoch)); return epoch
        }
        guard let token else { return }
        queue.async { [self] in
            let previous=lock.withLock { let value=ready; ready=nil; return value }
            if let previous { clip_close(previous) }
            guard lock.withLock({epoch==token}) else { if let reusing { clip_close(reusing) }; return }
            var error=[CChar](repeating:0,count:512)
            guard let media=reusing ?? clip_open(url.path,Int32(audioTrack),&error,512) else {
                lock.withLock { if epoch==token { self.key=nil } }; return
            }
            let prepared=clip_prepare(media,start,request,Int32(truncatingIfNeeded:token))==0
            let accepted=lock.withLock {
                guard epoch==token, prepared else { if epoch==token { self.key=nil }; return false }
                ready=media; return true
            }
            if !accepted { clip_close(media) }
        }
    }
    func take()->OpaquePointer? {
        lock.withLock { let value=ready; ready=nil; if value != nil { key=nil }; return value }
    }
    func cancel() {
        let old=lock.withLock { () -> OpaquePointer? in
            epoch += 1; key=nil; clip_request_set(request,Int32(truncatingIfNeeded:epoch))
            let value=ready; ready=nil; return value
        }
        // Removing ready is synchronous; destruction waits behind any preparation.
        if let old { queue.async { clip_close(old) } }
    }
}
