import AppKit
import AVFoundation
import CMedia
import Combine
import CoreImage

/// Keeps background media operations off the CALayer. Tests can observe these
/// operations while still forwarding to the layer's real video renderer.
class VideoOutput {
    let layer:AVSampleBufferDisplayLayer
    let renderer:AVSampleBufferVideoRenderer
    init(layer:AVSampleBufferDisplayLayer=AVSampleBufferDisplayLayer()) {
        self.layer=layer; renderer=layer.sampleBufferRenderer
    }
    var isReadyForMoreMediaData:Bool { renderer.isReadyForMoreMediaData }
    var status:AVQueuedSampleBufferRenderingStatus { renderer.status }
    var requiresFlushToResumeDecoding:Bool { renderer.requiresFlushToResumeDecoding }
    func enqueue(_ sample:CMSampleBuffer) { renderer.enqueue(sample) }
    func flush() { renderer.flush() }
    func removeImage() { renderer.flush(removingDisplayedImage:true,completionHandler:nil) }
}

final class Playback: ObservableObject {
    let video:AVSampleBufferDisplayLayer
    private let videoOutput:VideoOutput
    let audio:AVSampleBufferAudioRenderer
    let clock = AVSampleBufferRenderSynchronizer()
    let queue = DispatchQueue(label:"clipper.decode",qos:.userInteractive)
    private var media: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var pending: ClipSample?
    private var decodeFloor = 0.0
    private var running = false
    private var warmTransport=false
    private struct TimedFrame { var timeline:Double; var frame:FramePoint }
    private var frameTimes:[TimedFrame]=[]
    private let loopPreparation=LoopPreparation()
    private var audioTrack=0
    private var loopSource:(url:URL,audioTrack:Int)?
    @Published private(set) var loopGap=false
    // Range and live controls cross the main/decode queues only under requestLock.
    private var loopOn=false
    private var loopBounds=(start:0.0,end:0.0)
    private var timelinePeriod=0.0
    private var loopPeriodTime=CMTime.zero
    private var firstEndTime=CMTime.zero
    private var pumpBoundary=CMTime.zero
    private var committedEnd:Double?
    private var stopAt:Double?
    private var pass:Int32=0
    private var passPeriod=CMTime.zero
    private var passOffset=CMTime.zero
    private var endQueued=false
    private var audioCursor:Int64?
    private struct LoopBuffer {
        var buffer:CMSampleBuffer
        var kind:Int
        var time:Double
        var duration:Double
        var frame:FramePoint?
    }
    private var passCache:[LoopBuffer]=[]
    private var passCacheBytes=0
    private var cacheEligible=false
    private var replayIndex:Int?
    private let passCacheLimit=128*1024*1024
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
    @Published private(set) var transportWanted=false
    private var runID=UUID()
    private var boundaryObserver:Any?
    private var decodeEnd=Double.infinity
    // Demux/decode order can deliver audio past the cut before the final B-frames.
    private var videoPastCut=false
    private var audioPastCut=false
    private var runEnd=Double.infinity
    private var runStart=0.0
    private var runCompletion:(() -> Void)?

    init(videoOutput:VideoOutput=VideoOutput(),audio:AVSampleBufferAudioRenderer=AVSampleBufferAudioRenderer()) {
        self.videoOutput=videoOutput; video=videoOutput.layer; self.audio=audio
        video.videoGravity = .resize
        clock.addRenderer(videoOutput.renderer)
        clock.addRenderer(audio)
        clock.delaysRateChangeUntilHasSufficientMediaData = false
        observer = clock.addPeriodicTimeObserver(forInterval:CMTimeMake(value:1,timescale:30),queue:.main) { [weak self] time in
            guard let self, self.playing else { return }
            let t = time.seconds
            self.position = self.sourceTime(for:t)
            // The range observer stops the clock; the decoder enforces the exclusive cut.
        }
        let t = DispatchSource.makeTimerSource(queue:queue)
        t.schedule(deadline:.now(),repeating:.milliseconds(15))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume(); timer=t
    }
    deinit { if let boundaryObserver { clock.removeTimeObserver(boundaryObserver) }; timer?.cancel(); if let observer { clock.removeTimeObserver(observer) }; if let media { clip_close(media) }; clip_request_free(cancellation) }
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
        sourceURL=url; self.audioTrack=audioTrack; loopGap=false
        requestLock.withLock { loopSource=(url,audioTrack) }
        loopPreparation.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            self.running=false; self.primeToken=nil
            DispatchQueue.main.async { if self.isCurrent(token) { self.videoOutput.removeImage() } }
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
            let details=MediaDetails(duration:info.duration,origin:info.origin,width:Int(info.width),height:Int(info.height),rotation:info.rotation,pixelAspect:info.pixelAspect,fps:info.fps,hdr:info.hdr != 0,codec:codecText,audioLabels:(0..<info.audioCount).map { String(cString:clip_audio_label(m,$0)) },audioStreams:(0..<info.audioCount).map { Int(clip_audio_stream(m,$0)) },colorSpace:Int(info.colorSpace))
            DispatchQueue.main.async {
                guard self.isCurrent(token) else { return }
                self.details=details
                self.seek(time,onFailure:onFailure,completion:completion)
            }
        }
    }
    func seek(_ requested: Double, onFailure: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        cancelRun()
        let sameFrame=warmTransport && !playing && !seeking && frame.map { requested >= $0.time-0.0000001 && requested < $0.end-0.0000001 } == true
        // A no-op seek keeps the queued decoder generation valid for warm resume.
        if !sameFrame { _=nextGeneration() }
        loopPreparation.cancel()
        seekFrame(requested,onFailure:onFailure,completion:completion)
    }
    private func seekFrame(_ requested:Double,skipBackdrop:Bool=false,forcePresent:Bool=false,onFailure:(() -> Void)?=nil,completion:(() -> Void)?=nil) {
        if !forcePresent, warmTransport, !playing, !seeking, let frame, requested>=frame.time-0.0000001, requested<frame.end-0.0000001 {
            completion?(); runNextAction(); return
        }
        stopChasing()
        pauseRenderer(); warmTransport=false; starting=false; seeking=true
        let token=nextGeneration()
        let backdropSource=currentBackdropGeneration()
        let target=max(0,min(requested,max(0,(details?.duration ?? requested)-0.000001)))
        queue.async { [weak self] in
            guard let self, self.isCurrent(token), let m=self.media else { return }
            self.running=false; self.primeToken=nil; self.generation=token
            self.videoPastCut=false; self.audioPastCut=false
            self.resetLoopTimeline()
            clip_enable_cache(m)
            if let pending=self.pending, let sample=pending.sample { sample.release() }; self.pending=nil
            let frame=clip_frame_cancellable(m,target,self.cancellation,Int32(truncatingIfNeeded:token))
            guard frame.kind == 1, let unmanaged=frame.sample else {
                DispatchQueue.main.async { if self.isCurrent(token) { self.seeking=false; self.deferredActions=[]; self.error="Could not decode this frame."; onFailure?() } }; return
            }
            let sample=unmanaged.takeRetainedValue()
            let point=FramePoint(time:frame.time,duration:frame.duration,pts:frame.pts,timeBaseNum:frame.timeBaseNum,timeBaseDen:frame.timeBaseDen)
            var backdropPixel:CVPixelBuffer?
            if !skipBackdrop, self.isCurrent(token), !self.backdropTime.isFinite || abs(self.backdropTime-frame.time)>2,
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
        loopPreparation.cancel()
        deferredActions=[]; sourceURL=nil; requestLock.withLock { loopSource=nil }; details=nil; frame=nil; position=0; seeking=false; error=nil; backdrop=nil; endTime = .infinity
        queue.async { [weak self] in
            guard let self else { return }
            self.running=false; self.primeToken=nil; self.generation=token
            if let sample=self.pending?.sample { sample.release() }; self.pending=nil
            if let media=self.media { clip_close(media) }; self.media=nil
            DispatchQueue.main.async { if self.isCurrent(token) { self.videoOutput.removeImage() } }
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
        videoOutput.flush(); audio.flush()
        warmTransport=false
        requestLock.withLock { frameTimes=[]; timelinePeriod=0; committedEnd=nil; stopAt=nil }
        clock.setRate(0,time:CMTime(seconds:point.time,preferredTimescale:1000000))
        if let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:true) as? [NSMutableDictionary] { attachments.first?[kCMSampleAttachmentKey_DisplayImmediately]=true }
        videoOutput.enqueue(sample); position=point.time; frame=point
    }
    /// A preview clock can request new frames without cancelling an in-flight decode.
    /// Only the latest waiting target is retained; normal editing seeks remain separate.
    func chase(_ time:Double,completion:(() -> Void)?=nil) {
        guard details != nil else { return }
        cancelRun(); loopPreparation.cancel()
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
        cancelRun()
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
    /// The render clock stays monotonic across passes. Only source/UI time wraps.
    var currentSourceTime:Double { sourceTime(for:clock.currentTime().seconds) }
    private func sourceTime(for timeline:Double)->Double {
        requestLock.withLock {
            if let committedEnd, timeline>=committedEnd,
               let last=frameTimes.last(where:{$0.timeline<committedEnd-0.0000001}) { return last.frame.time }
            guard timelinePeriod>0, timeline>=loopBounds.end else { return max(0,timeline) }
            let iteration=floor((timeline-loopBounds.start)/timelinePeriod)
            return max(loopBounds.start,min(loopBounds.end,timeline-iteration*timelinePeriod))
        }
    }
    func prepareLoop(start:Double) {
        guard let sourceURL else { return }
        loopPreparation.prepare(url:sourceURL,audioTrack:audioTrack,start:start)
    }
    func setLooping(_ enabled:Bool) {
        requestLock.withLock { loopOn=enabled }
        if enabled {
            if transportWanted { prepareLoop(start:runStart) }
        } else if transportWanted || warmTransport {
            // Stop on the decode queue's current rational pass boundary, beyond queued heads.
            let now=clock.currentTime().seconds
            let boundary=requestLock.withLock { () -> Double in
                let p=max(0.000001,loopPeriodTime.seconds)
                let n=Int32(min(Double(Int32.max),max(0,ceil((now+0.03-firstEndTime.seconds)/p))))
                let wanted=CMTimeAdd(firstEndTime,CMTimeMultiply(loopPeriodTime,multiplier:n))
                let boundary=CMTimeMaximum(pumpBoundary,wanted).seconds
                stopAt=boundary; committedEnd=boundary; return boundary
            }
            audio.flush(fromSourceTime:CMTime(seconds:boundary,preferredTimescale:1000000000)) { _ in }
            if transportWanted { armBoundary(runID) }
        }
    }
    func play() {
        playRange(until:min(endTime,details?.duration ?? .infinity),loopStart:0)
    }
    func playRange(from:Double?=nil,until:Double,loopStart:Double,looping:Bool=false,onEnd:(() -> Void)?=nil) {
        pause()
        guard details != nil, until.isFinite, loopStart.isFinite, until>loopStart else { return }
        let id=runID
        let sameRange=requestLock.withLock { loopBounds.start==loopStart && loopBounds.end==until }
        runEnd=until; runStart=loopStart; runCompletion=onEnd; loopGap=false
        let scale=frame?.timeBaseDen ?? 1000000000
        // CMTime(seconds:) truncates at this scale. Round to the actual source tick.
        let period=CMTime(value:Int64(((until-loopStart)*Double(scale)).rounded()),timescale:scale)
        requestLock.withLock { decodeEnd=until; loopOn=looping; loopBounds=(loopStart,until); loopPeriodTime=period; firstEndTime=CMTime(seconds:until,preferredTimescale:1000000000) }
        transportWanted=true
        if looping { prepareLoop(start:loopStart) }
        let ready={ [weak self] in
            guard let self, self.runID==id, self.transportWanted else { return }
            self.armBoundary(id); self.playRenderer()
        }
        if let from { seekFrame(from,skipBackdrop:true,forcePresent:true,onFailure:{ [weak self] in self?.failRun() },completion:ready) }
        else if (!sameRange && warmTransport) || (looping && requestLock.withLock({stopAt != nil})) { seekFrame(position,skipBackdrop:true,forcePresent:true,onFailure:{ [weak self] in self?.failRun() },completion:ready) }
        else { afterPendingSeeks(ready) }
    }
    private func cancelRun() {
        runID=UUID(); transportWanted=false; runCompletion=nil
        if let boundaryObserver { clock.removeTimeObserver(boundaryObserver); self.boundaryObserver=nil }
    }
    private func armBoundary(_ id:UUID) {
        if let boundaryObserver { clock.removeTimeObserver(boundaryObserver); self.boundaryObserver=nil }
        let end=requestLock.withLock { committedEnd }
        guard let end else { return }
        let finish={ [weak self] in
            guard let self, self.runID==id, self.transportWanted else { return }
            self.finishRange(id)
        }
        if clock.currentTime().seconds>=end { finish(); return }
        boundaryObserver=clock.addBoundaryTimeObserver(forTimes:[NSValue(time:CMTime(seconds:end,preferredTimescale:1000000000))],queue:.main,using:finish)
    }
    private func finishRange(_ id:UUID) {
        if let boundaryObserver { clock.removeTimeObserver(boundaryObserver); self.boundaryObserver=nil }
        pauseRenderer()
        let repeatAfterGap=requestLock.withLock { () -> Bool in
            let repeatRequested=loopOn
            if repeatRequested { stopAt=nil }
            return repeatRequested
        }
        if repeatAfterGap {
            loopGap=true
            seekFrame(runStart,skipBackdrop:true,forcePresent:true,onFailure:{ [weak self] in self?.failRun() }) { [weak self] in
                guard let self, self.runID==id, self.transportWanted else { return }
                self.playRenderer()
            }
        } else {
            transportWanted=false
            let completion=runCompletion
            seekFrame(max(0,runEnd-0.000002),skipBackdrop:true,onFailure:{ [weak self] in
                guard let self, self.runID==id else { return }
                self.cancelRun(); completion?()
            },completion:{ [weak self] in
                guard let self, self.runID==id else { return }
                self.cancelRun(); completion?()
            })
        }
    }
    private func failRun() {
        let completion=runCompletion
        pause(); completion?()
    }
    private func playRenderer() {
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
            self.videoOutput.flush(); self.audio.flush()
            self.clock.setRate(0,time:CMTime(seconds:start,preferredTimescale:1000000))
            if let p=self.pending, let b=p.sample { b.release() }; self.pending=nil
            self.requestLock.withLock { self.frameTimes=[] }
            if clip_resume(m,start)==0 && clip_prepare(m,start,self.cancellation,Int32(truncatingIfNeeded:token))<0 {
                DispatchQueue.main.async { if self.isCurrent(token) { self.error="Could not start playback here."; self.failRun() } }
                return
            }
            self.decodeFloor=start; self.generation=token; self.running=true
            self.resetLoopTimeline()
            let range=self.requestLock.withLock { self.loopBounds }
            self.passPeriod=self.requestLock.withLock { self.loopPeriodTime }
            self.cacheEligible=abs(start-range.start)<0.000001 && self.requestLock.withLock({self.loopOn})
            self.requestLock.withLock { self.timelinePeriod=self.passPeriod.seconds; self.pumpBoundary=self.firstEndTime }
            clip_enable_cache(m)
            self.videoPastCut=false; self.audioPastCut=false
            self.primeToken=token; self.primedVideo=false; self.primedAudioEnd = .nan
            self.pump()
        }
    }
    func pause() { cancelRun(); pauseRenderer() }
    private func pauseRenderer() {
        if starting { starting=false; _=nextGeneration() }
        clock.setRate(0,time:.invalid)
        let time=clock.currentTime().seconds
        if playing, warmTransport {
            let point=requestLock.withLock { frameTimes.last(where:{$0.timeline<=time+0.000001})?.frame }
            if let point { frame=point; position=point.time }
        }
        playing=false
        queue.async { [weak self] in self?.running=false }
    }
    func toggle() { transportWanted ? pauseAndResolve() : play() }
    func pauseAndResolve() { pause() }
    func setMuted(_ muted: Bool) { audio.isMuted=muted }
    // Called only on the decode queue after a seek/cold start.
    private func resetLoopTimeline() {
        pass=0; passOffset = .zero; endQueued=false; audioCursor=nil
        passCache=[]; passCacheBytes=0; cacheEligible=false; replayIndex=nil
        requestLock.withLock { timelinePeriod=0; committedEnd=nil; stopAt=nil; pumpBoundary=firstEndTime }
    }
    private func commitEnd(_ time:Double) {
        guard !endQueued else { return }
        endQueued=true
        let token=generation
        requestLock.withLock { committedEnd=time }
        finishPrimingIfReady(at:clock.currentTime().seconds,atEnd:true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(token), self.transportWanted else { return }
            self.armBoundary(self.runID)
        }
    }
    private func nextPass()->Bool {
        guard isCurrent(generation) else { running=false; return false }
        let range=requestLock.withLock { loopBounds }
        let end=requestLock.withLock { CMTimeAdd(firstEndTime,passOffset).seconds }
        let repeatAllowed=requestLock.withLock { loopOn && (stopAt == nil || end < stopAt!-0.000001) }
        guard repeatAllowed else { commitEnd(end); return false }
        if cacheEligible && !passCache.isEmpty {
            if replayIndex == nil { loopPreparation.cancel() }
            replayIndex=0
        } else {
            guard let prepared=loopPreparation.take() else { commitEnd(end); return false }
            let old=media; media=prepared; clip_enable_cache(prepared)
            if let sample=pending?.sample { sample.release() }; pending=nil
            if let old {
                clip_set_cache(old,0)
                let handedOff=requestLock.withLock { () -> Bool in
                    guard latestRequest==generation, let source=loopSource else { return false }
                    // Scheduling and generation validation are atomic with open/close cancellation.
                    loopPreparation.prepare(url:source.url,audioTrack:source.audioTrack,start:range.start,reusing:old)
                    return true
                }
                if !handedOff { clip_close(old) }
            }
            passCache=[]; passCacheBytes=0; cacheEligible=true
        }
        pass += 1
        passOffset=CMTimeMultiply(passPeriod,multiplier:pass)
        requestLock.withLock { pumpBoundary=CMTimeAdd(firstEndTime,passOffset) }
        decodeFloor=range.start; videoPastCut=false; audioPastCut=false
        return true
    }
    private func remember(_ value:LoopBuffer) {
        guard cacheEligible, replayIndex == nil else { return }
        let bytes:Int
        if let pixel=CMSampleBufferGetImageBuffer(value.buffer) {
            bytes=max(CVPixelBufferGetDataSize(pixel),(0..<CVPixelBufferGetPlaneCount(pixel)).reduce(0) { $0+CVPixelBufferGetBytesPerRowOfPlane(pixel,$1)*CVPixelBufferGetHeightOfPlane(pixel,$1) })
        } else { bytes=CMSampleBufferGetTotalSampleSize(value.buffer) }
        if passCacheBytes+bytes>passCacheLimit || passCache.count>=20000 {
            cacheEligible=false; passCache=[]; passCacheBytes=0
        } else { passCache.append(value); passCacheBytes += bytes }
    }
    /// Shallow timing copies share their image/PCM data, never duplicate a decoded frame.
    private func scheduled(_ value:LoopBuffer)->CMSampleBuffer? {
        let offset=passOffset.seconds
        let range=requestLock.withLock { loopBounds }
        var buffer=value.buffer
        let time:CMTime, duration:CMTime
        if value.kind==2 {
            var start=Int64(((value.time+offset)*48000).rounded())
            if let audioCursor, abs(start-audioCursor)<=2 { start=audioCursor }
            let first=Int64(((max(range.start,decodeFloor)+offset)*48000).rounded())
            let last=Int64(((range.end+offset)*48000).rounded())
            let skip=max(0,first-start)
            let count=Int64(CMSampleBufferGetNumSamples(buffer))
            let keep=min(count-skip,last-(start+skip))
            guard keep>0 else { return nil }
            if skip>0 || keep<count {
                var trimmed:CMSampleBuffer?
                guard CMSampleBufferCopySampleBufferForRange(allocator:kCFAllocatorDefault,sampleBuffer:buffer,sampleRange:CFRange(location:Int(skip),length:Int(keep)),sampleBufferOut:&trimmed)==noErr, let trimmed else { return nil }
                buffer=trimmed
            }
            start += skip; audioCursor=start+keep
            time=CMTime(value:start,timescale:48000); duration=CMTime(value:1,timescale:48000)
        } else {
            time=CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer),passOffset)
            duration=CMTime(seconds:min(value.duration,range.end-value.time),preferredTimescale:1000000000)
        }
        var timing=CMSampleTimingInfo(duration:duration,presentationTimeStamp:time,decodeTimeStamp:.invalid)
        var copy:CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator:kCFAllocatorDefault,sampleBuffer:buffer,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleBufferOut:&copy)==noErr else { return nil }
        // A cached paused frame must not bypass the continuous presentation clock.
        if let attachments=copy.flatMap({CMSampleBufferGetSampleAttachmentsArray($0,createIfNecessary:true)}) as? [NSMutableDictionary] {
            attachments.first?.removeObject(forKey:kCMSampleAttachmentKey_DisplayImmediately)
        }
        return copy
    }
    private func pump() {
        guard running, !endQueued, isCurrent(generation), media != nil else { return }
        let now=clock.currentTime().seconds
        // Bound work per tick, including many passes of a one-frame loop.
        for _ in 0..<300 {
            guard isCurrent(generation), let m=media else { running=false; return }
            let value:LoopBuffer
            if let index=replayIndex {
                if index>=passCache.count { guard nextPass() else { return }; continue }
                value=passCache[index]
            } else {
                let sample:ClipSample
                if let p=pending { sample=p; pending=nil } else { sample=clip_next_cancellable(m,cancellation,Int32(truncatingIfNeeded:generation)) }
                if sample.kind<=0 {
                    if sample.kind == -3 || !isCurrent(generation) { running=false; return }
                    if sample.kind == -1 {
                        let token=generation
                        DispatchQueue.main.async { if self.isCurrent(token) { self.error="Playback decoding failed."; self.failRun() } }
                        running=false; return
                    }
                    guard primedVideo else {
                        let token=generation
                        DispatchQueue.main.async { if self.isCurrent(token) { self.failRun() } }
                        running=false; return
                    }
                    guard nextPass() else { return }; continue
                }
                guard let unmanaged=sample.sample else { continue }
                guard isCurrent(generation) else { unmanaged.release(); running=false; return }
                if sample.time < decodeFloor-0.000001 { unmanaged.release(); continue }
                let cutoff=requestLock.withLock { decodeEnd }
                if sample.time>=cutoff-0.0000001 {
                    if sample.kind==1 { videoPastCut=true } else { audioPastCut=true }
                    if (videoPastCut && (audioPastCut || clip_info(m).audioCount==0)) || sample.time>cutoff+1 {
                        pending=sample
                        guard nextPass() else { return }
                    } else { unmanaged.release() }
                    continue
                }
                let time=sample.time+passOffset.seconds
                if time>now+0.4 || (sample.kind==1 && !videoOutput.isReadyForMoreMediaData) || (sample.kind==2 && !audio.isReadyForMoreMediaData) {
                    pending=sample; finishPrimingIfReady(at:now,atEnd:true); return
                }
                let point=sample.kind==1 ? FramePoint(time:sample.time,duration:sample.duration,pts:sample.pts,timeBaseNum:sample.timeBaseNum,timeBaseDen:sample.timeBaseDen) : nil
                value=LoopBuffer(buffer:unmanaged.takeRetainedValue(),kind:Int(sample.kind),time:sample.time,duration:sample.duration,frame:point)
                remember(value)
            }
            let time=value.time+passOffset.seconds
            let stop=requestLock.withLock { stopAt }
            if let stop, time>=stop-0.0000001 { commitEnd(stop); return }
            if replayIndex != nil && (time>now+0.4 || (value.kind==1 && !videoOutput.isReadyForMoreMediaData) || (value.kind==2 && !audio.isReadyForMoreMediaData)) {
                // Only replay reaches this path; decoded values were checked before consumption.
                finishPrimingIfReady(at:now,atEnd:true); return
            }
            if replayIndex != nil { replayIndex! += 1 }
            guard let buffer=scheduled(value) else { continue }
            if value.kind==1 {
                if videoOutput.status == .failed || videoOutput.requiresFlushToResumeDecoding { videoOutput.flush() }
                videoOutput.enqueue(buffer); primedVideo=true
                if let point=value.frame {
                    requestLock.withLock {
                        frameTimes.append(TimedFrame(timeline:time,frame:point))
                        if frameTimes.count>192 { frameTimes.removeFirst(frameTimes.count-192) }
                    }
                }
            } else { audio.enqueue(buffer); primedAudioEnd=CMSampleBufferGetPresentationTimeStamp(buffer).seconds+CMSampleBufferGetDuration(buffer).seconds }
            finishPrimingIfReady(at:now,atEnd:primedAudioEnd >= (requestLock.withLock { loopBounds.end })+passOffset.seconds-0.00003)
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
