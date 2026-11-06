import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class Editor: ObservableObject {
    let playback=Playback()
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
    @Published var showOutput=false
    @Published var previewStart=0.0
    @Published var previewDuration=0.0
    let outputPlayer=AVPlayer()
    private var encoder: EncoderProcess?
    private var revision=UUID()
    private var loadingID=UUID()
    @Published private(set) var loading=false
    private var quitAfterExport=false
    var details: MediaDetails? { playback.details }
    var inTime: Double { start?.time ?? 0 }
    var outTime: Double { min(end?.end ?? details?.duration ?? 0,details?.duration ?? 0) }
    var clipDuration: Double { max(0,outTime-inTime) }
    var canExport: Bool { source != nil && start != nil && end != nil && clipDuration > 0 && !loading && !playback.seeking && !exporting }

    func openPanel() {
        let panel=NSOpenPanel()
        panel.allowedContentTypes=[.movie,.video,.mpeg4Movie,.quickTimeMovie,UTType(filenameExtension:"mkv") ?? .data,UTType(filenameExtension:"webm") ?? .data,UTType(filenameExtension:"avi") ?? .data]
        panel.allowsMultipleSelection=false; panel.canChooseDirectories=false
        if panel.runModal() == .OK, let url=panel.url { open(url) }
    }
    func open(_ url: URL) {
        guard !exporting else { error="Finish or cancel the current export before opening another video."; return }
        let id=UUID(); loadingID=id; loading=true
        invalidatePreview(); source=url; start=nil; end=nil; edit=EditSettings(); error=nil; lastExport=nil
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
    func seek(_ time: Double) { guard !loading else { return }; returnToOriginal(); playback.clearQueuedActions(); playback.seek(time) }
    func markStart(_ time: Double? = nil) {
        guard !exporting, !loading else { return }
        if time == nil && playback.seeking { playback.afterPendingSeeks { [weak self] in self?.markStart() }; return }
        invalidatePreview()
        playback.seek((time ?? playback.position)+(time == nil ? 0 : 0.0005)) { [weak self] in
            guard let self, let frame=self.playback.frame else { return }
            if frame.time < self.outTime { self.start=frame }
            else { self.error="The start must be before the end of the clip." }
        }
    }
    func markEnd(_ time: Double? = nil) {
        guard !exporting, !loading else { return }
        if time == nil && playback.seeking { playback.afterPendingSeeks { [weak self] in self?.markEnd() }; return }
        invalidatePreview()
        playback.seek((time ?? playback.position)+(time == nil ? 0 : 0.0005)) { [weak self] in
            guard let self, let frame=self.playback.frame else { return }
            if frame.end > self.inTime { self.end=frame; self.playback.endTime=self.outTime }
            else { self.error="The end must be after the start of the clip." }
        }
    }
    func settingsChanged(_ previous: EditSettings) {
        guard !loading else { return }
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
            playback.open(source,audioTrack:edit.audioTrack,at:t) { [weak self] in if let duration { self?.playback.details?.duration=duration } }
        }
        playback.setMuted(edit.muted)
    }
    func invalidatePreview() {
        revision=UUID(); outputPlayer.pause(); outputPlayer.replaceCurrentItem(with:nil); showOutput=false
        if let url=previewURL { try? FileManager.default.removeItem(at:url) }; previewURL=nil
        if exporting && jobLabel == "Rendering preview" { encoder?.cancel() }
    }
    func returnToOriginal() { if showOutput { outputPlayer.pause(); showOutput=false } }
    func togglePlayback() {
        guard !loading else { return }
        if showOutput {
            if outputPlayer.rate > 0 { outputPlayer.pause() }
            else {
                if outputPlayer.currentTime().seconds >= previewDuration-0.05 { outputPlayer.seek(to:.zero) }
                outputPlayer.play()
            }
        } else {
            if !playback.playing && playback.position >= outTime-0.00001 { playback.seek(inTime) { self.playback.play() } }
            else { playback.toggle() }
        }
    }
    func switchPreview(_ output: Bool) {
        playback.pause(); outputPlayer.pause()
        showOutput=output
        if output { outputPlayer.seek(to:.zero) }
        else { playback.seek(previewStart) }
    }
    func preview() {
        guard canExport else { return }
        let beginning=min(max(playback.position,inTime),max(inTime,outTime-0.000001))
        // At the selected end, start up to five seconds earlier for a useful sample.
        let from=outTime-beginning < 0.05 ? max(inTime,outTime-5) : beginning
        previewStart=from; previewDuration=min(5,outTime-from)
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("clipper-preview-\(UUID().uuidString).mp4")
        encode(destination:url,start:from,end:from+previewDuration,isPreview:true)
    }
    func export(saveAs: Bool = false) {
        guard canExport, let source else { return }
        var destination=uniqueOutput(for:source)
        if saveAs {
            let panel=NSSavePanel(); panel.allowedContentTypes=[.mpeg4Movie]; panel.nameFieldStringValue=destination.lastPathComponent
            panel.directoryURL=source.deletingLastPathComponent()
            panel.canCreateDirectories=true
            guard panel.runModal() == .OK, let url=panel.url else { return }; destination=url
            // Replacing a source or an existing output is intentionally never implicit.
            if FileManager.default.fileExists(atPath:destination.path) { error="Choose a new filename. Clipper never overwrites existing files."; return }
        }
        if destination.standardizedFileURL == source.standardizedFileURL { error="Choose a different filename from the source video."; return }
        encode(destination:destination,start:inTime,end:outTime,isPreview:false)
    }
    func uniqueOutput(for source: URL) -> URL {
        let parent=source.deletingLastPathComponent(), base=source.deletingPathExtension().lastPathComponent
        var n=1
        while true {
            let name=n == 1 ? "\(base)-clip.mp4" : "\(base)-clip-\(n).mp4"
            let url=parent.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath:url.path) { return url }; n += 1
        }
    }
    private func encode(destination: URL,start: Double,end: Double,isPreview: Bool) {
        guard let source, let details else { return }
        playback.pause(); outputPlayer.pause()
        let token=revision
        let temporary=destination.deletingLastPathComponent().appendingPathComponent(".clipper-\(UUID().uuidString).mp4")
        let job=EncoderProcess(); encoder=job
        let request=ExportRequest(source:source,details:details,edit:edit,start:start,end:end,destination:temporary)
        exporting=true; progress=0; error=nil; jobLabel=isPreview ? "Rendering preview" : "Exporting clip"
        Task {
            defer {
                exporting=false; encoder=nil; try? FileManager.default.removeItem(at:temporary)
                if quitAfterExport { invalidatePreview(); NSApp.reply(toApplicationShouldTerminate:true) }
            }
            do {
                try await job.run(request) { value in Task { @MainActor in self.progress=value } }
                if isPreview && token != revision { return }
                try FileManager.default.moveItem(at:temporary,to:destination)
                if isPreview {
                    if let old=previewURL { try? FileManager.default.removeItem(at:old) }
                    previewURL=destination; outputPlayer.replaceCurrentItem(with:AVPlayerItem(url:destination)); showOutput=true
                } else { lastExport=destination }
            } catch ExportFailure.cancelled { }
            catch { self.error=error.localizedDescription }
        }
    }
    func cancel() { encoder?.cancel() }
    func cancelAndQuit() { quitAfterExport=true; encoder?.cancel() }
    func revealExport() { if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) } }
}
