import Foundation
import Combine
import CMedia

struct WaveformPeaks {
    static let maximumBins=1_000_000
    let duration:Double
    let binWidth:Double
    let levels:[[Float]]
    var byteCount:Int { levels.reduce(0) { $0+$1.count*MemoryLayout<Float>.stride } }

    static func binCount(duration:Double)->Int {
        guard duration.isFinite, duration>0 else { return 0 }
        return Int(min(Double(maximumBins),max(1,ceil(duration/0.005))))
    }
    init(duration:Double,peaks:[Float]) {
        self.duration=duration; binWidth=duration/Double(peaks.count)
        var levels=[peaks]
        while let previous=levels.last, previous.count>1 {
            var next=[Float](repeating:0,count:(previous.count+1)/2)
            for i in next.indices { next[i]=max(previous[i*2],i*2+1<previous.count ? previous[i*2+1] : 0) }
            levels.append(next)
        }
        self.levels=levels
    }
    // At most three blocks per pixel column, even when the entire source is fitted.
    func peak(from start:Double,to end:Double)->Float {
        guard start<duration, end>0, end>start, !levels[0].isEmpty else { return 0 }
        let lower=min(levels[0].count-1,max(0,Int(floor(max(0,start)/binWidth))))
        let upper=min(levels[0].count,Int(ceil(min(duration,end)/binWidth)))
        let level=min(levels.count-1,Int(floor(log2(Double(max(1,upper-lower))))))
        let first=lower>>level, last=max(first,(upper-1)>>level)
        return levels[level][first...last].max() ?? 0
    }
    static func height(_ peak:Float)->Double {
        peak>0 ? max(0,min(1,(20*log10(Double(peak))+54)/54)) : 0
    }
}

/// The worker owns its reader and PCM frame. Cancellation may be set from any thread.
final class WaveformJob:@unchecked Sendable {
    private let condition=NSCondition()
    private var cancelled=false
    private var paused=false
    private var resumeAfter=Date().addingTimeInterval(0.3)
    let request=clip_request_create()!
    deinit { clip_request_free(request) }
    func cancel() {
        condition.lock(); cancelled=true; clip_request_set(request,1); condition.broadcast(); condition.unlock()
    }
    func setPaused(_ value:Bool) {
        condition.lock()
        if value != paused { paused=value; if !value { resumeAfter=Date().addingTimeInterval(0.3) } }
        condition.broadcast(); condition.unlock()
    }
    func checkpoint()->Bool {
        condition.lock(); defer { condition.unlock() }
        while !cancelled {
            if paused { condition.wait() }
            else if resumeAfter>Date() { condition.wait(until:resumeAfter) }
            else { return true }
        }
        return false
    }
    func generate(url:URL,stream:Int,origin:Double,duration:Double,progress:(Double)->Void) throws -> WaveformPeaks {
        guard checkpoint() else { throw CancellationError() }
        var error=[CChar](repeating:0,count:256)
        guard let reader=clip_waveform_open(url.path,Int32(stream),origin,request,0,&error,256) else {
            throw ExportFailure.message(String(cString:error))
        }
        defer { clip_waveform_close(reader) }
        let count=WaveformPeaks.binCount(duration:duration)
        guard count>0 else { throw ExportFailure.message("Unknown audio duration") }
        var peaks=[Float](repeating:0,count:count), position=0.0
        var reported=Date.distantPast
        while checkpoint() {
            let status=clip_waveform_step(reader,&peaks,Int32(count),duration/Double(count),&position,&error,256)
            if status<0 { throw ExportFailure.message(String(cString:error)) }
            if Date().timeIntervalSince(reported)>0.2 {
                progress(min(0.99,max(0,position/duration))); reported=Date()
            }
            if status==0 {
                guard checkpoint() else { throw CancellationError() }
                return WaveformPeaks(duration:duration,peaks:peaks)
            }
        }
        throw CancellationError()
    }
}

@MainActor final class AudioWaveform:ObservableObject {
    struct Key:Equatable { let url:URL; let stream:Int; let origin:Double; let duration:Double }
    @Published private(set) var peaks:WaveformPeaks?
    @Published private(set) var generating=false
    @Published private(set) var progress=0.0
    @Published private(set) var failure:String?
    @Published private(set) var paused=false
    private let queue=DispatchQueue(label:"clipper.waveform",qos:.utility)
    private var job:WaveformJob?
    private var key:Key?
    private var epoch=UUID()
    private var cache:[(Key,WaveformPeaks)]=[]
    var cachedTrackCount:Int { cache.count }

    deinit { job?.cancel() }
    func resetSource() {
        cancel(); cache=[]
    }
    func cancel() {
        job?.cancel(); job=nil; epoch=UUID(); key=nil
        peaks=nil; generating=false; progress=0; failure=nil
    }
    // Only used while quitting, before explicit temporary-import disposal.
    func cancelAndWait() { cancel(); queue.sync {} }
    func update(url:URL?,stream:Int,origin:Double,duration:Double,enabled:Bool,busy:Bool,lease:TemporaryImport?) {
        paused=busy; job?.setPaused(busy)
        guard enabled, let url, stream>=0, WaveformPeaks.binCount(duration:duration)>0 else {
            if key != nil { cancel() }; return
        }
        let next=Key(url:url,stream:stream,origin:origin,duration:duration)
        guard key != next else { return }
        cancel(); key=next
        if let index=cache.firstIndex(where:{$0.0==next}) {
            let hit=cache.remove(at:index); cache.append(hit); peaks=hit.1; return
        }
        let work=WaveformJob(), token=epoch
        job=work; generating=true; work.setPaused(busy)
        queue.async { [weak self, lease] in
            let result=Result { try work.generate(url:url,stream:stream,origin:origin,duration:duration) { fraction in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.epoch==token else { return }; self.progress=fraction
                }
            } }
            withExtendedLifetime(lease) {} // Keep managed sources until the reader has closed.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.epoch==token else { return }
                self.generating=false; self.job=nil
                switch result {
                case .success(let peaks):
                    // Make room before retaining the new completed track.
                    if self.cache.count>=2 { self.cache.removeFirst() }
                    self.cache.append((next,peaks)); self.peaks=peaks; self.progress=1
                case .failure(let error): self.failure=error.localizedDescription
                }
            }
        }
    }
}
