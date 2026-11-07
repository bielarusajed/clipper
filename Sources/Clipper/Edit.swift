import Foundation
import CoreGraphics

enum PreviewMode:String,CaseIterable,Identifiable {
    case original="Original", compare="Compare", output="Output"
    var id:Self { self }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264", hevc = "H.265"
    var id: Self { self }
    var encoder: String { self == .h264 ? "h264_videotoolbox" : "hevc_videotoolbox" }
}
enum Resolution: String, CaseIterable, Identifiable {
    case original = "Original", uhd = "4K", qhd = "1440p", hd = "1080p", small = "720p", tiny = "480p"
    var id: Self { self }
    var longEdge: Double { switch self { case .original: return .infinity; case .uhd: return 3840; case .qhd: return 2560; case .hd: return 1920; case .small: return 1280; case .tiny: return 854 } }
}
enum CropPreset: String, CaseIterable, Identifiable {
    case original = "Original", wide = "16:9", vertical = "9:16", square = "1:1", portrait = "4:5", custom = "Custom"
    var id: Self { self }
    var ratio: Double? { switch self { case .original, .custom: return nil; case .wide: return 16/9; case .vertical: return 9/16; case .square: return 1; case .portrait: return 4/5 } }
}
struct FramePoint: Equatable {
    let time: Double
    let duration: Double
    let pts: Int64
    let timeBaseNum: Int32
    let timeBaseDen: Int32
    var end: Double { time + duration }
}
struct MediaDetails {
    var duration: Double
    var origin: Double
    var width: Int
    var height: Int
    var rotation: Double
    var pixelAspect: Double
    var fps: Double
    var hdr: Bool
    var codec: String
    var audioLabels: [String]
    var audioStreams: [Int]
    var colorSpace:Int = 2 // AVColorSpace.unspecified; playback assumes 709 for untagged HD.
    var displaySize: CGSize {
        let size = CGSize(width: Double(width)*pixelAspect, height: Double(height))
        return abs(sin(rotation * .pi / 180)) > 0.5 ? CGSize(width: size.height, height: size.width) : size
    }
}
struct EditSettings: Equatable {
    var codec: VideoCodec = .h264
    var resolution: Resolution = .original
    var quality: Double = 65
    var cropPreset: CropPreset = .original
    var crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var customWidth: Double = 16
    var customHeight: Double = 9
    var audioTrack = 0
    var muted = false
    var convertToSDR = false

    mutating func setCrop(ratio: Double?, size: CGSize) {
        guard let ratio, ratio.isFinite, ratio > 0 else { crop = CGRect(x: 0,y: 0,width: 1,height: 1); return }
        let sourceRatio = size.width/size.height
        if ratio < sourceRatio { let w = ratio/sourceRatio; crop = CGRect(x: (1-w)/2,y: 0,width: w,height: 1) }
        else { let h = sourceRatio/ratio; crop = CGRect(x: 0,y: (1-h)/2,width: 1,height: h) }
    }
    /// Normalize once before recording, never while restoring an existing snapshot.
    mutating func normalize(previous:EditSettings,details:MediaDetails?) {
        if !customWidth.isFinite || customWidth <= 0 { customWidth=previous.customWidth }
        if !customHeight.isFinite || customHeight <= 0 { customHeight=previous.customHeight }
        if !(customWidth/customHeight).isFinite || customWidth/customHeight <= 0 {
            customWidth=previous.customWidth; customHeight=previous.customHeight
        }
        quality=quality.isFinite ? max(20,min(95,quality)) : previous.quality
        if let details {
            if cropPreset != previous.cropPreset || (cropPreset == .custom && (customWidth != previous.customWidth || customHeight != previous.customHeight)) {
                setCrop(ratio:cropPreset == .custom ? customWidth/customHeight : cropPreset.ratio,size:details.displaySize)
            }
            if details.hdr && !convertToSDR { codec = .hevc }
            audioTrack=max(0,min(max(0,details.audioLabels.count-1),audioTrack))
        }
        if !crop.minX.isFinite || !crop.minY.isFinite || !crop.width.isFinite || !crop.height.isFinite || crop.width <= 0 || crop.height <= 0 {
            crop=previous.crop
        }
        crop.size=CGSize(width:min(1,crop.width),height:min(1,crop.height))
        crop.origin=CGPoint(x:max(0,min(1-crop.width,crop.minX)),y:max(0,min(1-crop.height,crop.minY)))
    }
    func geometry(for details: MediaDetails) -> (x: Int,y: Int,width: Int,height: Int,outWidth: Int,outHeight: Int) {
        func even(_ value: Double) -> Int { max(2,Int(value/2)*2) }
        let size = details.displaySize
        let width = min(even(size.width),even(crop.width*size.width))
        let height = min(even(size.height),even(crop.height*size.height))
        let x = max(0,min(Int(size.width)-width,Int(crop.minX*size.width)/2*2))
        let y = max(0,min(Int(size.height)-height,Int(crop.minY*size.height)/2*2))
        let scale = min(1,resolution.longEdge/Double(max(width,height)))
        return (x,y,width,height,even(Double(width)*scale),even(Double(height)*scale))
    }
}
enum TimeText {
    static func format(_ seconds: Double) -> String {
        let ms = max(0,Int((seconds*1000).rounded()))
        return String(format:"%02d:%02d:%02d.%03d",ms/3600000,ms/60000%60,ms/1000%60,ms%1000)
    }
    static func parse(_ value: String) -> Double? {
        let pieces = value.trimmingCharacters(in:.whitespaces).split(separator:":",omittingEmptySubsequences:false)
        guard (1...3).contains(pieces.count) else { return nil }
        var total = 0.0
        for p in pieces { guard let n = Double(p), n.isFinite, n >= 0 else { return nil }; total = total*60+n }
        return total
    }
}

struct EditSnapshot:Equatable {
    var start:FramePoint?
    var end:FramePoint?
    var settings:EditSettings
}
