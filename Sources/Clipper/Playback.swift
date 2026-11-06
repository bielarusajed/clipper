import AppKit
import AVFoundation
import CMedia
import Combine
import CoreImage

final class Playback: ObservableObject {
    let video:AVSampleBufferDisplayLayer
    let audio = AVSampleBufferAudioRenderer()
    let clock = AVSampleBufferRenderSynchronizer()
    let queue = DispatchQueue(label:"clipper.decode",qos:.userInteractive)
    private var media: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var pending: ClipSample?
    private var decodeFloor = 0.0
    private var running = false
    private var warmTransport=false
    private var frameTimes:[FramePoint]=[]
    private var primeToken:Int?
    private var primedVideo=false
    private var primedAudioEnd=Double.nan
    @Published private(set) var starting=false
    private var generation = 0
    private var latestRequest = 0
    private let requestLock = NSLock()
    private let cancellation=clip_request_create()!
    private var observer: Any?
    private var deferredActions: [() -> Void] = []
    private struct ChaseRequest { var time:Double; var completion:(() -> Void)? }
    private var chaseTarget:ChaseRequest?
    private var chaseRunning=false
    private var chaseEpoch=0
    private let imageQueue=DispatchQueue(label:"clipper.backdrop",qos:.utility)
    private var sourceURL: URL?
    private let imageContext=CIContext(options:[.cacheIntermediates:false])
    private var backdropTime=Double.nan
    private var backdropGeneration=0
    @Published private(set) var backdrop:NSImage?
    @Published var details: MediaDetails?
    @Published var frame: FramePoint?
    @Published var position: Double = 0
    @Published var playing = false
    @Published var seeking = false
    @Published var error: String?
    var endTime = Double.infinity

    init(video:AVSampleBufferDisplayLayer=AVSampleBufferDisplayLayer()) {
        self.video=video
        video.videoGravity = .resize
        clock.addRenderer(video)
        clock.addRenderer(audio)
        clock.delaysRateChangeUntilHasSufficientMediaData = false
        observer = clock.addPeriodicTimeObserver(forInterval:CMTimeMake(value:1,timescale:30),queue:.main) { [weak self] time in
            guard let self, self.playing else { return }
            let t = time.seconds
            self.position = max(0,t)
            if t >= min(self.endTime,self.details?.duration ?? .infinity) { self.seek(max(0,min(self.endTime,self.details?.duration ?? t)-0.000002)) }
        }
        let t = DispatchSource.makeTimerSource(queue:queue)
        t.schedule(deadline:.now(),repeating:.milliseconds(15))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume(); timer=t
    }
    deinit { timer?.cancel(); if let observer { clock.removeTimeObserver(observer) }; if let media { clip_close(media) }; clip_request_free(cancellation) }
    private func nextGeneration() -> Int {
        requestLock.lock(); defer { requestLock.unlock() }
        latestRequest += 1; clip_request_set(cancellation,Int32(truncatingIfNeeded:latestRequest)); return latestRequest
    }
    private func isCurrent(_ value: Int) -> Bool {
        requestLock.lock(); defer { requestLock.unlock() }
        return latestRequest == value
    }
    func open(_ url: URL, audioTrack: Int = 0, at time: Double = 0, onFailure: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        stopChasing()
        resetBackdrop()
        deferredActions=[]
        pause(); warmTransport=false; starting=false; seeking=true; error=nil
        let token=nextGeneration()
        sourceURL=url
        queue.async { [weak self] in
            guard let self else { return }
            self.running=false; self.primeToken=nil
            DispatchQueue.main.async { if self.isCurrent(token) { self.video.flushAndRemoveImage() } }
            self.audio.flush()
            if let pending=self.pending, let sample=pending.sample { sample.release() }; self.pending=nil
            if let media=self.media { clip_close(media) }; self.media=nil
            var error=[CChar](repeating:0,count:512)
            guard let m=clip_open(url.path,Int32(audioTrack),&error,512) else {
                let message=String(cString:error)
                DispatchQueue.main.async { if self.isCurrent(token) { self.error="Could not open video: \(message)"; self.seeking=false; self.details=nil; onFailure?() } }; return
            }
            clip_enable_cache(m)
            self.media=m; self.generation=token; self.backdropTime = .nan
            let info=clip_info(m)
            var codec=info.codec
            let codecText=withUnsafePointer(to:&codec) { $0.withMemoryRebound(to:CChar.self,capacity:64) { String(cString:$0) } }
            let details=MediaDetails(duration:info.duration,origin:info.origin,width:Int(info.width),height:Int(info.height),rotation:info.rotation,pixelAspect:info.pixelAspect,fps:info.fps,hdr:info.hdr != 0,codec:codecText,audioLabels:(0..<info.audioCount).map { String(cString:clip_audio_label(m,$0)) },audioStreams:(0..<info.audioCount).map { Int(clip_audio_stream(m,$0)) })
            DispatchQueue.main.async {
                guard self.isCurrent(token) else { return }
                self.details=details
                self.seek(time,onFailure:onFailure,completion:completion)
            }
        }
    }
    func seek(_ requested: Double, onFailure: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        if warmTransport, !playing, !seeking, let frame, requested>=frame.time-0.0000001, requested<frame.end-0.0000001 {
            completion?(); runNextAction(); return
        }
        stopChasing()
        pause(); warmTransport=false; starting=false; seeking=true
        let token=nextGeneration()
        let backdropSource=currentBackdropGeneration()
        let target=max(0,min(requested,max(0,(details?.duration ?? requested)-0.000001)))
        queue.async { [weak self] in
            guard let self, self.isCurrent(token), let m=self.media else { return }
            self.running=false; self.primeToken=nil; self.generation=token
            if let pending=self.pending, let sample=pending.sample { sample.release() }; self.pending=nil
            let frame=clip_frame_cancellable(m,target,self.cancellation,Int32(truncatingIfNeeded:token))
            guard frame.kind == 1, let unmanaged=frame.sample else {
                DispatchQueue.main.async { if self.isCurrent(token) { self.seeking=false; self.deferredActions=[]; self.error="Could not decode this frame."; onFailure?() } }; return
            }
            let sample=unmanaged.takeRetainedValue()
            let point=FramePoint(time:frame.time,duration:frame.duration,pts:frame.pts,timeBaseNum:frame.timeBaseNum,timeBaseDen:frame.timeBaseDen)
            var backdropPixel:CVPixelBuffer?
            if self.isCurrent(token), !self.backdropTime.isFinite || abs(self.backdropTime-frame.time)>2,
               let pixel=CMSampleBufferGetImageBuffer(sample) {
                backdropPixel=pixel; self.backdropTime=frame.time
            }
            if let pixel=backdropPixel { self.makeBackdrop(pixel,sourceToken:backdropSource) }
            DispatchQueue.main.async {
                guard self.isCurrent(token) else { return }
                self.present(sample,point:point); self.seeking=false
                completion?()
                self.runNextAction()
            }
        }
    }
    func close() {
        stopChasing()
        resetBackdrop()
        pause(); warmTransport=false; starting=false; let token=nextGeneration()
        deferredActions=[]; sourceURL=nil; details=nil; frame=nil; position=0; seeking=false; error=nil; backdrop=nil; endTime = .infinity
        queue.async { [weak self] in
            guard let self else { return }
            self.running=false; self.primeToken=nil; self.generation=token
            if let sample=self.pending?.sample { sample.release() }; self.pending=nil
            if let media=self.media { clip_close(media) }; self.media=nil
            DispatchQueue.main.async { if self.isCurrent(token) { self.video.flushAndRemoveImage() } }
            self.audio.flush(); self.backdropTime = .nan
        }
    }
    private func resetBackdrop() {
        requestLock.withLock { backdropGeneration += 1 }
        backdrop=nil
    }
    private func currentBackdropGeneration()->Int { requestLock.withLock { backdropGeneration } }
    private func makeBackdrop(_ pixel:CVPixelBuffer,sourceToken:Int) {
        imageQueue.async { [weak self] in
            guard let self, self.currentBackdropGeneration()==sourceToken else { return }
            var image=CIImage(cvPixelBuffer:pixel)
            image=image.transformed(by:CGAffineTransform(scaleX:160/image.extent.width,y:160/image.extent.width))
            guard let cg=self.imageContext.createCGImage(image,from:image.extent) else { return }
            DispatchQueue.main.async { if self.currentBackdropGeneration()==sourceToken { self.backdrop=NSImage(cgImage:cg,size:.zero) } }
        }
    }
    private func present(_ sample:CMSampleBuffer,point:FramePoint) {
        video.flush(); audio.flush()
        warmTransport=false
        requestLock.withLock { frameTimes=[] }
        clock.setRate(0,time:CMTime(seconds:point.time,preferredTimescale:1000000))
        if let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:true) as? [NSMutableDictionary] { attachments.first?[kCMSampleAttachmentKey_DisplayImmediately]=true }
        video.enqueue(sample); position=point.time; frame=point
    }
    /// A preview clock can request new frames without cancelling an in-flight decode.
    /// Only the latest waiting target is retained; normal editing seeks remain separate.
    func chase(_ time:Double,completion:(() -> Void)?=nil) {
        guard details != nil else { return }
        warmTransport=false; starting=false
        chaseTarget=ChaseRequest(time:time,completion:completion)
        startNextChase()
    }
    func stopChasing() {
        chaseEpoch += 1; chaseTarget=nil
        if chaseRunning { _=nextGeneration() }
        chaseRunning=false
    }
    private func startNextChase() {
        guard !chaseRunning, let request=chaseTarget else { return }
        if seeking {
            let epoch=chaseEpoch
            afterPendingSeeks { [weak self] in if self?.chaseEpoch==epoch { self?.startNextChase() } }
            return
        }
        chaseTarget=nil; chaseRunning=true
        let epoch=chaseEpoch, token=nextGeneration()
        let time=max(0,min(request.time,(details?.duration ?? request.time)-0.000001))
        queue.async { [weak self] in
            guard let self, self.isCurrent(token), let media=self.media else { return }
            self.running=false
            if let sample=self.pending?.sample { sample.release() }; self.pending=nil
            let value=clip_frame_cancellable(media,time,self.cancellation,Int32(truncatingIfNeeded:token))
            let sample=value.sample?.takeRetainedValue()
            DispatchQueue.main.async {
                guard self.chaseEpoch==epoch, self.isCurrent(token) else { return }
                self.chaseRunning=false
                if value.kind==1, let sample {
                    self.present(sample,point:FramePoint(time:value.time,duration:value.duration,pts:value.pts,timeBaseNum:value.timeBaseNum,timeBaseDen:value.timeBaseDen))
                }
                request.completion?()
                self.startNextChase()
            }
        }
    }
    func step(_ direction: Int,onFailure:(() -> Void)?=nil,completion:(() -> Void)?=nil) {
        if seeking { deferredActions.append { [weak self] in self?.step(direction,onFailure:onFailure,completion:completion) }; return }
        if playing { let t=position; seek(t,onFailure:onFailure) { self.step(direction,onFailure:onFailure,completion:completion) }; return }
        guard let frame else { return }
        if direction > 0 { seek(frame.end + 0.000002,onFailure:onFailure,completion:completion); return }
        // The containing frame just before this PTS is the exact predecessor.
        seek(max(0,frame.time-0.000002),onFailure:onFailure,completion:completion)
    }
    func afterPendingSeeks(_ action: @escaping () -> Void) {
        if seeking || !deferredActions.isEmpty { deferredActions.append(action) } else { action() }
    }
    func clearQueuedActions() { deferredActions=[] }
    private func runNextAction() {
        guard !seeking, !deferredActions.isEmpty else { return }
        deferredActions.removeFirst()()
        if !seeking { runNextAction() }
    }
    func play() {
        if seeking { playing=true; afterPendingSeeks { [weak self] in if self?.playing == true { self?.play() } }; return }
        guard details != nil else { return }
        playing=true
        if starting { return }
        if warmTransport {
            clock.setRate(1,time:.invalid)
            queue.async { [weak self] in guard let self else { return }; self.running=true; self.pump() }
            return
        }
        let start=position, token=nextGeneration()
        starting=true
        queue.async { [weak self] in
            guard let self, let m=self.media, self.isCurrent(token) else { return }
            self.video.flush(); self.audio.flush()
            self.clock.setRate(0,time:CMTime(seconds:start,preferredTimescale:1000000))
            if let p=self.pending, let b=p.sample { b.release() }; self.pending=nil
            self.requestLock.withLock { self.frameTimes=[] }
            if clip_resume(m,start)==0 && clip_seek(m,start)<0 {
                DispatchQueue.main.async { if self.isCurrent(token) { self.starting=false; self.playing=false; self.error="Could not start playback here." } }
                return
            }
            self.decodeFloor=start; self.generation=token; self.running=true
            self.primeToken=token; self.primedVideo=false; self.primedAudioEnd = .nan
            self.pump()
        }
    }
    func pause() {
        if starting { starting=false; _=nextGeneration() }
        clock.setRate(0,time:.invalid)
        let time=clock.currentTime().seconds
        if playing, warmTransport {
            let point=requestLock.withLock { frameTimes.last(where:{$0.time<=time+0.000001}) }
            if let point { frame=point; position=point.time }
        }
        playing=false
        queue.async { [weak self] in self?.running=false }
    }
    func toggle() { playing ? pauseAndResolve() : play() }
    func pauseAndResolve() { pause() }
    func setMuted(_ muted: Bool) { audio.isMuted=muted }
    private func pump() {
        guard running, isCurrent(generation), let m=media else { return }
        let now=clock.currentTime().seconds
        for _ in 0..<100 {
            guard isCurrent(generation) else { running=false; return }
            let sample: ClipSample
            if let p=pending { sample=p; pending=nil } else { sample=clip_next_cancellable(m,cancellation,Int32(truncatingIfNeeded:generation)) }
            if sample.kind <= 0 {
                running=false
                if let token=primeToken, !primedVideo {
                    primeToken=nil
                    DispatchQueue.main.async { if self.isCurrent(token) { self.starting=false; self.playing=false } }
                }
                if sample.kind == -1 { DispatchQueue.main.async { self.error="Playback decoding failed."; self.pause() } }
                finishPrimingIfReady(at:now,atEnd:true)
                return
            }
            guard let unmanaged=sample.sample else { continue }
            guard isCurrent(generation) else { unmanaged.release(); running=false; return }
            if sample.time < decodeFloor-0.000001 { unmanaged.release(); continue }
            if sample.time > now+0.3 || (sample.kind == 1 && !video.isReadyForMoreMediaData) || (sample.kind == 2 && !audio.isReadyForMoreMediaData) {
                pending=sample; finishPrimingIfReady(at:now,atEnd:true); return
            }
            let buffer=unmanaged.takeRetainedValue()
            if sample.kind == 1 {
                if video.status == .failed || video.requiresFlushToResumeDecoding { video.flush() }
                video.enqueue(buffer); primedVideo=true
                let point=FramePoint(time:sample.time,duration:sample.duration,pts:sample.pts,timeBaseNum:sample.timeBaseNum,timeBaseDen:sample.timeBaseDen)
                requestLock.withLock { frameTimes.append(point); if frameTimes.count>96 { frameTimes.removeFirst(frameTimes.count-96) } }
            } else { audio.enqueue(buffer); primedAudioEnd=sample.time+sample.duration }
            finishPrimingIfReady(at:now)
        }
    }
    private func finishPrimingIfReady(at time:Double,atEnd:Bool=false) {
        guard let token=primeToken, primedVideo,
              atEnd || primedAudioEnd>=time+0.08 || media.map({clip_info($0).audioCount==0}) == true else { return }
        primeToken=nil
        DispatchQueue.main.async { [self] in
            guard self.isCurrent(token) else { return }
            self.starting=false; self.warmTransport=true
            if self.playing {
                self.clock.setRate(1,time:.invalid)
                self.queue.async { [weak self] in guard let self, self.isCurrent(token) else { return }; self.running=true }
            }
        }
    }

}
