import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class Editor: ObservableObject {
    let playback=Playback()
    let urlImporter=URLImport()
    @Published var importPresented=false
    private var temporarySource:TemporaryImport?
    @Published var source: URL?
    @Published var edit=EditSettings()
    @Published var start: FramePoint?
    @Published var end: FramePoint?
    @Published var exporting=false
    @Published var progress=0.0
    @Published var jobLabel=""
    @Published var error: String?
    @Published var lastExport: URL?
    @Published var previewURL: URL?
    @Published private(set) var previewMode=PreviewMode.original
    @Published private(set) var previewReady=false
    @Published private(set) var previewPosition=0.0
    @Published private(set) var previewPlaying=false
    @Published private(set) var loopEnabled=false
    @Published private(set) var auditioning=false
    private var transportOperation=UUID()
    var canAudition:Bool { source != nil && start != nil && end != nil && clipDuration>0 && !loading && !exporting && !importPresented }
    var auditionHelp:String {
        if previewMode != .original && !previewCoversCut { return "Audition the cut in Original, outside this encoded sample (⇧⌘L)" }
        return "Play the last second before the selected end (⇧⌘L)"
    }
    private var previewCoversCut:Bool { previewStart+previewDuration >= outTime-0.000001 }
    private var encodedDuration:Double {
        let duration=outputPlayer.currentItem?.duration.seconds ?? .nan
        return duration.isFinite && duration>0 ? min(duration,previewDuration) : previewDuration
    }
    @Published private(set) var comparisonPreparing=false
    @Published var previewStart=0.0
    @Published var previewDuration=0.0
    @Published private(set) var nextOutputURL:URL?
    @Published var timelineZoom=0.0
    var maximumTimelineZoom:Double { max(0.01,min(16,log2(max(1,min(8_000_000,(details?.duration ?? 1)*(details?.fps ?? 30)*150)/1000)))) }
    func zoomTimeline(by amount:Double) { timelineZoom=max(0,min(maximumTimelineZoom,timelineZoom+amount)) }
    @Published private(set) var boundaryRevision=0
    private(set) var lastBoundaryIsStart=true
    let outputPlayer=AVPlayer()
    private var encoder: EncoderProcess?
    private var revision=UUID()
    private var loadingID=UUID()
    @Published private(set) var loading=false
    private var quitAfterExport=false
    private var previewStatus:NSKeyValueObservation?
    private var previewObserver:Any?
    private var previewEndObserver:NSObjectProtocol?
    private var previewEpoch=UUID()
    private var previewOperation=UUID()
    private var previewSteps:[Int]=[]
    private var previewStepRunning=false
    private var afterPreviewSteps:[() -> Void]=[]
    private var desiredPreviewPlay=false
    private struct BoundaryNudge { var start:Bool; var direction:Int }
    private var nudges:[BoundaryNudge]=[]
    private var nudgeRunning=false
    private var nudgeEpoch=UUID()
    var showOutput:Bool { previewMode == .output }
    var displayedPosition:Double { previewMode == .original ? playback.position : previewStart+previewPosition }
    var isPlaying:Bool { previewMode == .original ? playback.transportWanted : auditioning || previewPlaying || desiredPreviewPlay }
    var details: MediaDetails? { playback.details }
    var inTime: Double { start?.time ?? 0 }
    var outTime: Double { min(end?.end ?? details?.duration ?? 0,details?.duration ?? 0) }
    var clipDuration: Double { max(0,outTime-inTime) }
    var canExport: Bool { source != nil && start != nil && end != nil && clipDuration > 0 && !loading && !playback.seeking && !previewStepRunning && !exporting && !importPresented }

    init() {
        outputPlayer.actionAtItemEnd = .pause
        outputPlayer.automaticallyWaitsToMinimizeStalling=false
    }
    deinit {
        if let previewObserver { outputPlayer.removeTimeObserver(previewObserver) }
        if let previewEndObserver { NotificationCenter.default.removeObserver(previewEndObserver) }
    }

    var canPasteImport:Bool { !exporting && !importPresented && !urlImporter.busy }
    func paste(_ input:ClipboardImport) {
        guard canPasteImport else { return }
        switch input {
        case .file(let url): open(url)
        case .web(let url): showURLImporter(url:url)
        }
    }
    func showURLImporter(url:URL?=nil) {
        guard !exporting, !importPresented else { return }
        urlImporter.begin(url:url)
        interruptTransport(); importPresented=true
    }
    func openPanel() {
        guard !urlImporter.busy else { return }
        let panel=NSOpenPanel()
        panel.allowedContentTypes=[.movie,.video,.mpeg4Movie,.quickTimeMovie,UTType(filenameExtension:"mkv") ?? .data,UTType(filenameExtension:"webm") ?? .data,UTType(filenameExtension:"avi") ?? .data]
        panel.allowsMultipleSelection=false; panel.canChooseDirectories=false
        if panel.runModal() == .OK, let url=panel.url { open(url) }
    }
    func open(_ url: URL, temporary:TemporaryImport?=nil) {
        guard !urlImporter.busy else { error="Finish or cancel the URL import before opening another video."; return }
        guard !exporting else { error="Finish or cancel the current export before opening another video."; return }
        let previous=temporarySource
        temporarySource=temporary
        defer { if let previous { playback.queue.async { withExtendedLifetime(previous) {} } } }
        interruptTransport(); loopEnabled=false
        cancelNudges(); timelineZoom=0
        let id=UUID(); loadingID=id; loading=true
        invalidatePreview(); source=url; start=nil; end=nil; edit=EditSettings(); error=nil; lastExport=nil; nextOutputURL=uniqueOutput(for:url)
        playback.setMuted(false)
        playback.open(url,onFailure:{ [weak self] in self?.loading=false }) { [weak self] in
            guard let self, self.loadingID==id, let info=self.details else { return }
            if info.hdr { self.edit.codec = .hevc }
            self.start=self.playback.frame
            self.playback.seek(max(0,info.duration-0.000001),onFailure:{
                self.loading=false
                self.end=FramePoint(time:info.duration,duration:0,pts:0,timeBaseNum:1,timeBaseDen:1000000)
                self.playback.seek(self.inTime)
            }) {
                guard self.loadingID==id else { return }
                self.end=self.playback.frame
                if let last=self.end, last.end > 0 { self.playback.details?.duration=last.end }
                self.playback.endTime=self.outTime
                self.loading=false
                self.playback.seek(self.inTime)
            }
        }
    }
    func close() {
        guard !exporting, !urlImporter.busy else { return }
        interruptTransport(); loopEnabled=false
        cancelNudges()
        loadingID=UUID(); loading=false
        invalidatePreview(); playback.close()
        let previous=temporarySource; temporarySource=nil
        if let previous { playback.queue.async { withExtendedLifetime(previous) {} } }
        source=nil; start=nil; end=nil; edit=EditSettings(); lastExport=nil; nextOutputURL=nil; error=nil
    }
    func prepareToQuit() {
        let download=temporarySource
        close()
        download?.dispose()
    }
    func nudgeBoundary(start:Bool,direction:Int) {
        guard !loading, !exporting else { return }
        interruptTransport(); returnToOriginal()
        nudges.append(BoundaryNudge(start:start,direction:direction)); processNudge()
    }
    private func cancelNudges() { nudgeEpoch=UUID(); nudges=[]; nudgeRunning=false }
    private func processNudge() {
        guard !nudgeRunning, !nudges.isEmpty else { return }
        if playback.seeking {
            nudgeRunning=true; let epoch=nudgeEpoch
            playback.afterPendingSeeks { [weak self] in
                guard let self, self.nudgeEpoch==epoch else { return }
                self.nudgeRunning=false; self.processNudge()
            }
            return
        }
        nudgeRunning=true
        let action=nudges.removeFirst(), epoch=nudgeEpoch
        let finish={ [weak self] in guard let self, self.nudgeEpoch==epoch else { return }; self.nudgeRunning=false; self.processNudge() }
        let failure={ [weak self] in guard let self, self.nudgeEpoch==epoch else { return }; self.nudges=[]; self.refreshBoundary(start:action.start); finish() }
        let target=action.start ? inTime : end?.time ?? outTime
        playback.seek(target,onFailure:failure,completion:{ [weak self] in
            guard let self, self.nudgeEpoch==epoch else { return }
            self.playback.step(action.direction,onFailure:failure,completion:{ [weak self] in
                guard let self, self.nudgeEpoch==epoch, let frame=self.playback.frame else { return }
                self.invalidatePreview(); self.commitBoundary(frame,start:action.start); finish()
            })
        })
    }
    private func commitBoundary(_ frame:FramePoint,start:Bool) {
        if start {
            if frame.time<outTime { self.start=frame }
            else { error="The start must be before the end of the clip." }
        } else {
            if frame.end>inTime { self.end=frame; playback.endTime=outTime }
            else { error="The end must be after the start of the clip." }
        }
        refreshBoundary(start:start)
    }
    private func refreshBoundary(start:Bool) { lastBoundaryIsStart=start; boundaryRevision += 1 }
    func seek(_ time: Double) { guard !loading else { return }; interruptTransport(); cancelNudges(); returnToOriginal(); playback.clearQueuedActions(); playback.seek(time) }
    func markStart(_ time: Double? = nil) {
        guard !exporting, !loading else { return }
        cancelNudges(); auditioning=false
        if time == nil, previewStepRunning { afterPreviewSteps.append { [weak self] in self?.markStart() }; return }
        if time == nil, previewMode != .original { let t=previewStart+currentOutputTime; invalidatePreview(); markStart(t); return }
        if time == nil && playback.seeking { playback.afterPendingSeeks { [weak self] in self?.markStart() }; return }
        invalidatePreview()
        playback.seek((time ?? playback.position)+(time == nil ? 0 : 0.0005),onFailure:{ [weak self] in self?.refreshBoundary(start:true) },completion:{ [weak self] in
            guard let self, let frame=self.playback.frame else { return }
            self.commitBoundary(frame,start:true)
        })
    }
    func markEnd(_ time: Double? = nil) {
        guard !exporting, !loading else { return }
        cancelNudges(); auditioning=false
        if time == nil, previewStepRunning { afterPreviewSteps.append { [weak self] in self?.markEnd() }; return }
        if time == nil, previewMode != .original { let t=previewStart+currentOutputTime; invalidatePreview(); markEnd(t); return }
        if time == nil && playback.seeking { playback.afterPendingSeeks { [weak self] in self?.markEnd() }; return }
        invalidatePreview()
        playback.seek((time ?? playback.position)+(time == nil ? 0 : 0.0005),onFailure:{ [weak self] in self?.refreshBoundary(start:false) },completion:{ [weak self] in
            guard let self, let frame=self.playback.frame else { return }
            self.commitBoundary(frame,start:false)
        })
    }
    func settingsChanged(_ previous: EditSettings) {
        guard !loading else { return }
        cancelNudges()
        invalidatePreview()
        if edit.cropPreset != previous.cropPreset, let details {
            let ratio=edit.cropPreset == .custom ? edit.customWidth/edit.customHeight : edit.cropPreset.ratio
            edit.setCrop(ratio:ratio,size:details.displaySize)
        } else if (edit.customWidth != previous.customWidth || edit.customHeight != previous.customHeight), edit.cropPreset == .custom, let details {
            edit.setCrop(ratio:edit.customWidth/edit.customHeight,size:details.displaySize)
        }
        if details?.hdr == true && !edit.convertToSDR { edit.codec = .hevc }
        if edit.audioTrack != previous.audioTrack, let source {
            let t=playback.position
            let duration=details?.duration
            playback.open(source,audioTrack:edit.audioTrack,at:t,completion:{ [weak self] in if let duration { self?.playback.details?.duration=duration } })
        }
        playback.setMuted(edit.muted)
    }
    func invalidatePreview() {
        if previewMode != .original { interruptTransport() }
        revision=UUID(); stopPreviewTracking(); previewStatus=nil
        outputPlayer.pause(); outputPlayer.replaceCurrentItem(with:nil)
        previewMode = .original; previewReady=false; previewPosition=0
        playback.setMuted(edit.muted)
        if let url=previewURL { try? FileManager.default.removeItem(at:url) }; previewURL=nil
        if exporting && jobLabel == "Rendering preview" { encoder?.cancel() }
    }
    func returnToOriginal() { if previewMode != .original { switchPreviewMode(.original) } }
    /// Loop is a preference for the current source; changing it never starts transport.
    func toggleLoop() { guard canAudition else { return }; loopEnabled.toggle() }
    private func interruptTransport(cancelSteps:Bool=true) {
        transportOperation=UUID(); auditioning=false
        playback.pause()
        if cancelSteps {
            previewSteps=[]; afterPreviewSteps=[]; previewStepRunning=false
            playback.stopChasing()
        }
        if !previewStepRunning { previewOperation=UUID(); comparisonPreparing=false }
        desiredPreviewPlay=false; previewPlaying=false
        outputPlayer.pause()
    }
    func auditionCut() {
        guard canAudition else { return }
        cancelNudges()
        if previewMode != .original && !previewCoversCut { returnToOriginal() }
        interruptTransport(); auditioning=true
        let operation=transportOperation
        if previewMode == .original {
            playback.playRange(from:max(inTime,outTime-1),until:outTime,loopStart:inTime,shouldLoop:{ false },onEnd:{ [weak self] in
                guard self?.transportOperation==operation else { return }; self?.auditioning=false
            })
        } else {
            // Resolve through source timestamps so VFR auditions begin on a whole frame.
            playback.seek(previewStart+max(0,encodedDuration-1),onFailure:{ [weak self] in self?.interruptTransport() }) { [weak self] in
                guard let self, self.transportOperation==operation else { return }
                self.seekOutput(max(0,(self.playback.frame?.time ?? self.previewStart)-self.previewStart),playAfter:true)
            }
        }
    }
    func togglePlayback() {
        guard canAudition else { return }
        cancelNudges()
        if isPlaying {
            let time=currentOutputTime
            interruptTransport()
            if previewMode != .original { seekOutput(time,playAfter:false) }
            return
        }
        auditioning=false
        if previewMode != .original {
            guard previewReady else { return }
            if previewStepRunning { afterPreviewSteps.append { [weak self] in self?.togglePlayback() }; return }
            let time=currentOutputTime >= encodedDuration-0.03 ? 0 : currentOutputTime
            seekOutput(time,playAfter:true)
        } else {
            let atEnd=(playback.frame?.end ?? playback.position) >= outTime-0.000001
            let outside=playback.position<inTime || playback.position>=outTime
            playback.playRange(from:atEnd || outside ? inTime : nil,until:outTime,loopStart:inTime,shouldLoop:{ [weak self] in self?.loopEnabled == true })
        }
    }
    func switchPreview(_ output: Bool) {
        switchPreviewMode(output ? .output : .original)
    }
    func switchPreviewMode(_ mode:PreviewMode) {
        guard mode == .original || (previewReady && previewURL != nil && !loading && !exporting) else { return }
        guard mode != previewMode else { return }
        cancelNudges(); interruptTransport()
        let time=previewMode == .original ? max(0,min(playback.position-previewStart,max(0,previewDuration-0.000002))) : currentOutputTime
        stopPreviewTracking(); outputPlayer.pause(); playback.pause()
        previewMode=mode; playback.setMuted(mode == .compare ? true : edit.muted)
        if mode == .original { playback.seek(min(outTime-0.000002,previewStart+previewDuration-0.000002,previewStart+time+0.000002)) }
        else { startPreviewTracking(); seekOutput(time,playAfter:false) }
    }
    private var outputSourceTime:Double {
        min(outTime-0.000002,previewStart+previewDuration-0.000002,previewStart+currentOutputTime+0.000002)
    }
    private var currentOutputTime:Double {
        let time=outputPlayer.currentTime().seconds
        return time.isFinite ? max(0,min(time,max(0,encodedDuration-0.000002))) : 0
    }
    private func stopPreviewTracking() {
        previewEpoch=UUID(); previewOperation=UUID()
        if let previewObserver { outputPlayer.removeTimeObserver(previewObserver); self.previewObserver=nil }
        if let previewEndObserver { NotificationCenter.default.removeObserver(previewEndObserver); self.previewEndObserver=nil }
        previewSteps=[]; afterPreviewSteps=[]; previewStepRunning=false; comparisonPreparing=false; previewPlaying=false; desiredPreviewPlay=false
        playback.stopChasing()
    }
    private func startPreviewTracking() {
        let epoch=previewEpoch, token=revision
        previewObserver=outputPlayer.addPeriodicTimeObserver(forInterval:CMTime(value:1,timescale:30),queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.previewEpoch==epoch, self.revision==token, self.previewMode != .original else { return }
                self.previewPosition=self.currentOutputTime
                if self.previewMode == .compare, self.previewPlaying, !self.comparisonPreparing, !self.previewStepRunning {
                    self.playback.chase(self.outputSourceTime)
                }
            }
        }
        previewEndObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:outputPlayer.currentItem,queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.previewEpoch==epoch, self.revision==token else { return }
                guard self.previewPlaying, self.currentOutputTime >= self.encodedDuration-0.04 else { return }
                self.previewPlaying=false; self.previewPosition=self.currentOutputTime
                if self.loopEnabled && !self.auditioning { self.seekOutput(0,playAfter:true) }
                else {
                    self.auditioning=false
                    self.seekOutput(max(0,self.encodedDuration-0.000002),playAfter:false)
                }
            }
        }
    }
    private func seekOutput(_ time:Double,playAfter:Bool) {
        guard !previewStepRunning else { return }
        let operation=UUID(); previewOperation=operation
        let epoch=previewEpoch, token=revision
        outputPlayer.pause(); previewPlaying=false; desiredPreviewPlay=playAfter
        comparisonPreparing=previewMode == .compare
        outputPlayer.seek(to:CMTime(seconds:time,preferredTimescale:1000000),toleranceBefore:.zero,toleranceAfter:.zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.previewOperation==operation, self.previewEpoch==epoch, self.revision==token, self.previewMode != .original else { return }
                guard finished else { self.comparisonPreparing=false; self.desiredPreviewPlay=false; self.auditioning=false; return }
                self.previewPosition=self.currentOutputTime
                let ready={ [weak self] in
                    guard let self, self.previewOperation==operation, self.previewEpoch==epoch, self.revision==token else { return }
                    self.comparisonPreparing=false
                    self.desiredPreviewPlay=false
                    if playAfter { self.previewPlaying=true; self.outputPlayer.play() }
                }
                if self.previewMode == .compare { self.playback.chase(self.outputSourceTime,completion:ready) }
                else { ready() }
            }
        }
    }
    func stepFrame(_ direction:Int) {
        guard !loading, !exporting else { return }
        cancelNudges(); interruptTransport(cancelSteps:false)
        if previewMode == .original { playback.step(direction); return }
        guard previewReady, previewSteps.count<64 else { return }
        previewSteps.append(direction); processPreviewStep()
    }
    private func processPreviewStep() {
        guard !previewStepRunning, !previewSteps.isEmpty, previewMode != .original else { return }
        let direction=previewSteps.removeFirst(), epoch=previewEpoch, token=revision
        previewStepRunning=true; outputPlayer.pause(); previewPlaying=false; desiredPreviewPlay=false; comparisonPreparing=true
        playback.stopChasing()
        let operation=UUID(); previewOperation=operation
        let valid={ [weak self] in self?.previewEpoch==epoch && self?.revision==token && self?.previewOperation==operation }
        let finish={ [weak self] in
            guard let self, valid() else { return }
            self.comparisonPreparing=false; self.previewStepRunning=false
            if self.previewSteps.isEmpty {
                let actions=self.afterPreviewSteps; self.afterPreviewSteps=[]
                for action in actions { action() }
            } else { self.processPreviewStep() }
        }
        let failure={ [weak self] in guard let self, valid() else { return }; self.previewSteps=[]; self.afterPreviewSteps=[]; finish() }
        playback.seek(outputSourceTime,onFailure:failure) { [weak self] in
            guard let self, valid() else { return }
            self.playback.step(direction,onFailure:failure) { [weak self] in
                guard let self, valid(), let frame=self.playback.frame else { return }
                let time=max(0,min(frame.time-self.previewStart,self.previewDuration-0.000002))
                self.outputPlayer.seek(to:CMTime(seconds:time,preferredTimescale:1000000),toleranceBefore:.zero,toleranceAfter:.zero) { [weak self] finished in
                    Task { @MainActor in
                        guard let self, valid() else { return }
                        guard finished else { failure(); return }
                        self.previewPosition=self.currentOutputTime
                        if self.previewMode == .compare { self.playback.chase(self.outputSourceTime,completion:finish) }
                        else { finish() }
                    }
                }
            }
        }
    }
    private func installPreview(_ url:URL) {
        stopPreviewTracking(); previewStatus=nil
        previewMode = .original; previewReady=false; previewPosition=0
        let item=AVPlayerItem(url:url), token=revision
        outputPlayer.replaceCurrentItem(with:item)
        previewStatus=item.observe(\.status,options:[.initial,.new]) { [weak self] item,_ in
            Task { @MainActor in
                guard let self, self.revision==token, self.outputPlayer.currentItem===item else { return }
                self.previewReady=item.status == .readyToPlay
                if self.previewReady { self.switchPreviewMode(.output) }
                else if item.status == .failed { self.error=item.error?.localizedDescription ?? "Could not open the encoded preview." }
            }
        }
    }
    func preview() {
        guard canExport else { return }
        let beginning=min(max(playback.position,inTime),max(inTime,outTime-0.000001))
        // At the selected end, start up to five seconds earlier for a useful sample.
        let from=outTime-beginning < 0.05 ? max(inTime,outTime-5) : beginning
        let duration=min(5,outTime-from)
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("clipper-preview-\(UUID().uuidString).mp4")
        encode(destination:url,start:from,end:from+duration,isPreview:true)
    }
    func export(saveAs: Bool = false) {
        guard canExport, let source else { return }
        var destination=uniqueOutput(for:source)
        var replacingExisting=false
        if saveAs || temporarySource != nil {
            let panel=NSSavePanel(); panel.allowedContentTypes=[.mpeg4Movie]; panel.nameFieldStringValue=destination.lastPathComponent
            panel.directoryURL=destination.deletingLastPathComponent()
            panel.canCreateDirectories=true
            let validator=ExportSavePanelValidator(source:source)
            panel.delegate=validator
            guard withExtendedLifetime(validator,{ panel.runModal() }) == .OK, let url=panel.url else { return }; destination=url
            replacingExisting=FileManager.default.fileExists(atPath:destination.path)
        }
        export(to:destination,replacingExisting:replacingExisting)
    }
    func export(to destination:URL,replacingExisting:Bool) {
        guard canExport, let source else { return }
        do { try ExportDestination.validate(source:source,destination:destination) }
        catch { self.error=error.localizedDescription; return }
        encode(destination:destination,start:inTime,end:outTime,isPreview:false,replacingExisting:replacingExisting)
    }
    func uniqueOutput(for source: URL) -> URL {
        let parent=temporarySource?.file == source
            ? FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0]
            : source.deletingLastPathComponent()
        let base=source.deletingPathExtension().lastPathComponent
        var n=1
        while true {
            let name=n == 1 ? "\(base)-clip.mp4" : "\(base)-clip-\(n).mp4"
            let url=parent.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath:url.path) { return url }; n += 1
        }
    }
    private func encode(destination: URL,start: Double,end: Double,isPreview: Bool,replacingExisting:Bool=false) {
        guard let source, let details else { return }
        interruptTransport(); stopPreviewTracking(); previewMode = .original; playback.setMuted(edit.muted)
        playback.pause(); outputPlayer.pause()
        let token=revision
        let temporary=destination.deletingLastPathComponent().appendingPathComponent(".clipper-\(UUID().uuidString).mp4")
        let job=EncoderProcess(); encoder=job
        let request=ExportRequest(source:source,details:details,edit:edit,start:start,end:end,destination:temporary)
        exporting=true; progress=0; error=nil; jobLabel=isPreview ? "Rendering preview" : "Exporting clip"
        Task {
            defer {
                exporting=false; encoder=nil; try? FileManager.default.removeItem(at:temporary)
                if quitAfterExport { invalidatePreview(); prepareToQuit(); NSApp.reply(toApplicationShouldTerminate:true) }
            }
            do {
                try await job.run(request) { value in Task { @MainActor in self.progress=value } }
                if isPreview && token != revision { return }
                try ExportDestination.publish(temporary,to:destination,source:source,replacingExisting:replacingExisting)
                if isPreview {
                    if let old=previewURL { try? FileManager.default.removeItem(at:old) }
                    previewStart=start; previewDuration=end-start; previewURL=destination; installPreview(destination)
                } else { lastExport=destination; nextOutputURL=uniqueOutput(for:source) }
            } catch ExportFailure.cancelled { }
            catch { self.error=error.localizedDescription }
        }
    }
    func cancel() { encoder?.cancel() }
    func cancelAndQuit() { quitAfterExport=true; encoder?.cancel() }
    func revealExport() { if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) } }
}

@MainActor final class ExportSavePanelValidator:NSObject,NSOpenSavePanelDelegate {
    let source:URL
    init(source:URL) { self.source=source }
    func panel(_ sender:Any,validate url:URL) throws {
        try ExportDestination.validate(source:source,destination:url)
    }
}
