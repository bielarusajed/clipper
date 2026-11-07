import Foundation
import CoreFoundation

/// Only intentional export choices belong here. Source-specific settings and
/// automatic HDR normalization must never be written back as preferences.
final class ExportPreferences {
    enum Key {
        static let codec="export.preferredCodec"
        static let quality="export.quality"
        static let saveDirectory="export.saveDirectory"
    }
    private let defaults:UserDefaults
    private let downloadsDirectory:URL

    init(defaults:UserDefaults = .standard,downloadsDirectory:URL?=nil) {
        self.defaults=defaults
        self.downloadsDirectory=downloadsDirectory
            ?? FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads",isDirectory:true)
    }

    var codec:VideoCodec {
        defaults.string(forKey:Key.codec) == "hevc" ? .hevc : .h264
    }
    var quality:Double {
        guard let number=defaults.object(forKey:Key.quality) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (20...95).contains(number.doubleValue) else { return 65 }
        return number.doubleValue.rounded()
    }
    func setCodec(_ codec:VideoCodec) {
        defaults.set(codec == .h264 ? "h264" : "hevc",forKey:Key.codec)
    }
    func setQuality(_ quality:Double) {
        guard quality.isFinite, (20...95).contains(quality) else { return }
        defaults.set(quality.rounded(),forKey:Key.quality)
    }
    func makeSettings() -> EditSettings {
        var settings=EditSettings()
        settings.codec=codec; settings.quality=quality
        return settings
    }

    func recordSaveDirectory(from chosenFile:URL) {
        guard chosenFile.isFileURL else { return }
        defaults.set(chosenFile.deletingLastPathComponent().standardizedFileURL.path,forKey:Key.saveDirectory)
    }
    func resolvedSaveDirectory() -> URL {
        if let path=defaults.string(forKey:Key.saveDirectory), path.hasPrefix("/") {
            let directory=URL(fileURLWithPath:path,isDirectory:true)
            if isAvailable(directory) { return directory }
        }
        if isAvailable(downloadsDirectory) { return downloadsDirectory }
        // A missing Downloads directory should not leave the panel in a stale
        // location. The user can create or choose a folder in the save panel.
        return FileManager.default.homeDirectoryForCurrentUser
    }
    private func isAvailable(_ directory:URL) -> Bool {
        let files=FileManager.default
        var isDirectory:ObjCBool=false
        return files.fileExists(atPath:directory.path,isDirectory:&isDirectory) && isDirectory.boolValue
            && files.isReadableFile(atPath:directory.path) && files.isWritableFile(atPath:directory.path)
    }
}
