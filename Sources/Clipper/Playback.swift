import AppKit
import AVFoundation
import CMedia
import Combine

final class Playback: ObservableObject {
    let video = AVSampleBufferDisplayLayer()
    let audio = AVSampleBufferAudioRenderer()
    let clock = AVSampleBufferRenderSynchronizer()
    let queue = DispatchQueue(label:"clipper.decode",qos:.userInteractive)
    private var media: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var pending: ClipSample?
    private var decodeFloor = 0.0
    private var running = false
    private var generation = 0
    private var latestRequest = 0
    private let requestLock = NSLock()
    private let cancellation=clip_request_create()!
    private var observer: Any?
    private var cachedTimes: [Double] = []
    private var sourceURL: URL?
    @Published var details: MediaDetails?
    @Published var frame: FramePoint?
    @Published var position: Double = 0
    @Published var playing = false
    @Published var seeking = false
    @Published var error: String?
    var endTime = Double.infinity

    init() {
        video.videoGravity = .resizeAspect
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
    func open(_ url: URL, audioTrack: Int = 0, at time: Double = 0, completion: (() -> Void)? = nil) {
        pause(); seeking=true; error=nil
        let token=nextGeneration()
        sourceURL=url
        queue.async { [weak self] in
            guard let self else { return }
            self.running=false
            if let pending=self.pending, let sample=pending.sample { sample.release() }; self.pending=nil
            if let media=self.media { clip_close(media) }; self.media=nil
            var error=[CChar](repeating:0,count:512)
            guard let m=clip_open(url.path,Int32(audioTrack),&error,512) else {
                let message=String(cString:error)
                DispatchQueue.main.async { if self.isCurrent(token) { self.error="Could not open video: \(message)"; self.seeking=false; self.details=nil } }; return
            }
            clip_enable_cache(m)
            self.media=m; self.generation=token; self.cachedTimes=[]
            let info=clip_info(m)
            var codec=info.codec
            let codecText=withUnsafePointer(to:&codec) { $0.withMemoryRebound(to:CChar.self,capacity:64) { String(cString:$0) } }
            let details=MediaDetails(duration:info.duration,origin:info.origin,width:Int(info.width),height:Int(info.height),rotation:info.rotation,pixelAspect:info.pixelAspect,fps:info.fps,hdr:info.hdr != 0,codec:codecText,audioLabels:(0..<info.audioCount).map { String(cString:clip_audio_label(m,$0)) },audioStreams:(0..<info.audioCount).map { Int(clip_audio_stream(m,$0)) })
            DispatchQueue.main.async {
                guard self.isCurrent(token) else { return }
                self.details=details
                self.seek(time,completion:completion)
            }
        }
    }
    func seek(_ requested: Double, completion: (() -> Void)? = nil) {
        pause(); seeking=true
        let token=nextGeneration()
        let target=max(0,min(requested,max(0,(details?.duration ?? requested)-0.000001)))
        queue.async { [weak self] in
            guard let self, self.isCurrent(token), let m=self.media else { return }
            self.running=false; self.generation=token
            if let pending=self.pending, let sample=pending.sample { sample.release() }; self.pending=nil
            let frame=clip_frame_cancellable(m,target,self.cancellation,Int32(truncatingIfNeeded:token))
            guard frame.kind == 1, let unmanaged=frame.sample else {
                DispatchQueue.main.async { if self.isCurrent(token) { self.seeking=false; self.error="Could not decode this frame." } }; return
            }
            let sample=unmanaged.takeRetainedValue()
            self.cachedTimes.append(frame.time)
            self.cachedTimes=Array(Set(self.cachedTimes)).sorted()
            let point=FramePoint(time:frame.time,duration:frame.duration,pts:frame.pts,timeBaseNum:frame.timeBaseNum,timeBaseDen:frame.timeBaseDen)
            DispatchQueue.main.async {
                guard self.isCurrent(token) else { return }
                self.video.flushAndRemoveImage(); self.audio.flush()
                self.clock.setRate(0,time:CMTime(seconds:frame.time,preferredTimescale:1000000))
                // A paused display must replace its image immediately.
                if let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:true) as? [NSMutableDictionary] { attachments.first?[kCMSampleAttachmentKey_DisplayImmediately]=true }
                self.video.enqueue(sample)
                self.position=frame.time; self.frame=point; self.seeking=false
                completion?()
            }
        }
    }
    func step(_ direction: Int) {
        if playing { let t=position; seek(t) { self.step(direction) }; return }
        guard let frame else { return }
        if direction > 0 { seek(frame.end + 0.000002); return }
        // The containing frame just before this PTS is the exact predecessor.
        seek(max(0,frame.time-0.000002))
    }
    func play() {
        guard !seeking, media != nil else { return }
        let start=position; let token=nextGeneration()
        playing=true
        video.flushAndRemoveImage(); audio.flush()
        clock.setRate(0,time:CMTime(seconds:start,preferredTimescale:1000000))
        queue.async { [weak self] in
            guard let self, let m=self.media, self.isCurrent(token) else { return }
            if let p=self.pending, let b=p.sample { b.release() }; self.pending=nil
            if clip_seek(m,start) < 0 { return }
            self.decodeFloor=start; self.generation=token; self.running=true
            self.pump()
            DispatchQueue.main.async { if self.isCurrent(token), self.playing { self.clock.setRate(1,time:CMTime(seconds:start,preferredTimescale:1000000)) } }
        }
    }
    func pause() {
        playing=false; clock.setRate(0,time:.invalid)
        queue.async { [weak self] in self?.running=false }
    }
    func toggle() { playing ? pauseAndResolve() : play() }
    func pauseAndResolve() { let t=position; pause(); seek(t) }
    func setMuted(_ muted: Bool) { audio.isMuted=muted }
    private func pump() {
        guard running, isCurrent(generation), let m=media else { return }
        let now=clock.currentTime().seconds
        for _ in 0..<100 {
            let sample: ClipSample
            if let p=pending { sample=p; pending=nil } else { sample=clip_next(m) }
            if sample.kind <= 0 {
                running=false
                if sample.kind < 0 { DispatchQueue.main.async { self.error="Playback decoding failed."; self.pause() } }
                return
            }
            guard let unmanaged=sample.sample else { continue }
            if sample.time < decodeFloor-0.000001 { unmanaged.release(); continue }
            if sample.time > now+0.7 || (sample.kind == 1 && !video.isReadyForMoreMediaData) || (sample.kind == 2 && !audio.isReadyForMoreMediaData) {
                pending=sample; return
            }
            let buffer=unmanaged.takeRetainedValue()
            if sample.kind == 1 { video.enqueue(buffer) } else { audio.enqueue(buffer) }
        }
    }
}
