import XCTest
import CMedia
import CoreImage
@testable import Clipper

final class MediaTests:XCTestCase {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func fixture(_ name:String)->URL { root.appendingPathComponent(".build/fixtures/"+name) }
    func open(_ url:URL) throws -> OpaquePointer {
        var error=[CChar](repeating:0,count:512)
        guard let m=clip_open(url.path,0,&error,512) else { throw ExportFailure.message(String(cString:error)) }; return m
    }
    func frames(_ url:URL) throws -> [(Double,Double)] {
        let m=try open(url); defer { clip_close(m) }
        var values:[(Double,Double)]=[]
        while true {
            let sample=clip_next(m)
            if sample.kind == 0 { break }
            XCTAssertGreaterThan(sample.kind,0,"Decode failed for \(url.lastPathComponent)")
            if sample.kind < 0 { break }
            if let unmanaged=sample.sample {
                let buffer=unmanaged.takeRetainedValue()
                if sample.kind == 1 { values.append((sample.time,luma(buffer))) }
            }
        }
        return values
    }
    func luma(_ sample:CMSampleBuffer)->Double {
        let pixel=CMSampleBufferGetImageBuffer(sample)!
        let image=CIImage(cvPixelBuffer:pixel).applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:CGRect(x:0,y:0,width:CVPixelBufferGetWidth(pixel),height:CVPixelBufferGetHeight(pixel)))])
        var data=[UInt8](repeating:0,count:4)
        CIContext().render(image,toBitmap:&data,rowBytes:4,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        return Double(data[0])
    }
    func details(_ info:ClipInfo)->MediaDetails {
        MediaDetails(duration:info.duration,origin:info.origin,width:Int(info.width),height:Int(info.height),rotation:info.rotation,pixelAspect:info.pixelAspect,fps:info.fps,hdr:info.hdr != 0,codec:"test",audioLabels:["Audio"],audioStreams:[1])
    }
    func testAllInputFormatsDecodeAndSeekToContainingFrame() throws {
        for name in ["cfr.mp4","vfr.mkv","vp9.webm","av1.webm","legacy.avi","offset.mkv"] {
            let url=fixture(name)
            guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Run scripts/make-fixtures.sh first") }
            let all=try frames(url)
            XCTAssertGreaterThan(all.count,40,name)
            guard !all.isEmpty else { continue }
            let m=try open(url); defer { clip_close(m) }
            for target in [0.13,1.111,2.501,4.219,5.9] {
                let expected=all.last(where:{$0.0 <= target+0.000001}) ?? all[0]
                let sample=clip_frame(m,target)
                XCTAssertEqual(sample.kind,1,name)
                XCTAssertEqual(sample.time,expected.0,accuracy:0.000002,"\(name) at \(target)")
                if let unmanaged=sample.sample { unmanaged.release() }
            }
        }
    }
    func testHardwareExportsPreserveChosenFirstLastFramesAndVFR() async throws {
        for name in ["cfr.mp4","vfr.mkv","vp9.webm","offset.mkv"] {
            for codec in VideoCodec.allCases {
                let url=fixture(name)
                let all=try frames(url)
                let m=try open(url); let info=clip_info(m); clip_close(m)
                let chosen=Array(all.filter { $0.0 >= 1.2 && $0.0 < 2.8 })
                let next=all.first(where:{$0.0 > chosen.last!.0})!.0
                let output=fixture("output-\(name)-\(codec.rawValue).mp4")
                try? FileManager.default.removeItem(at:output)
                defer { try? FileManager.default.removeItem(at:output) }
                var edit=EditSettings(); edit.codec=codec; edit.quality=90
                let request=ExportRequest(source:url,details:details(info),edit:edit,start:chosen[0].0,end:next,destination:output)
                try await EncoderProcess().run(request) { _ in }
                let encoded=try frames(output)
                XCTAssertEqual(encoded.count,chosen.count,"\(name) \(codec)")
                guard encoded.count==chosen.count else { continue }
                for i in encoded.indices {
                    XCTAssertEqual(encoded[i].0,chosen[i].0-chosen[0].0,accuracy:0.002,"Timing \(name) frame \(i)")
                    XCTAssertEqual(encoded[i].1,chosen[i].1,accuracy:4,"Identity \(name) frame \(i)")
                }
            }
        }
    }
    func testHDRPreserveAndSDRConversion() async throws {
        let source=fixture("hdr.mp4")
        let m=try open(source); let info=clip_info(m); clip_close(m)
        XCTAssertEqual(info.hdr,1)
        for sdr in [false,true] {
            var edit=EditSettings(); edit.codec = sdr ? .h264 : .hevc; edit.convertToSDR=sdr
            let output=fixture(sdr ? "sdr-output.mp4" : "hdr-output.mp4")
            try? FileManager.default.removeItem(at:output); defer { try? FileManager.default.removeItem(at:output) }
            try await EncoderProcess().run(ExportRequest(source:source,details:details(info),edit:edit,start:0,end:1,destination:output)) { _ in }
            let decoded=try open(output); defer { clip_close(decoded) }
            XCTAssertEqual(clip_info(decoded).hdr,sdr ? 0 : 1)
        }
    }
    func testCropNeverUpscalesAndPreservesRatio() {
        let info=MediaDetails(duration:10,origin:0,width:3840,height:2160,rotation:0,pixelAspect:1,fps:30,hdr:false,codec:"hevc",audioLabels:[],audioStreams:[])
        var edit=EditSettings(); edit.setCrop(ratio:9/16,size:info.displaySize); edit.resolution = .hd
        let g=edit.geometry(for:info)
        XCTAssertEqual(g.outHeight,1920); XCTAssertEqual(Double(g.outWidth)/Double(g.outHeight),9/16,accuracy:0.002)
        XCTAssertEqual(g.outHeight%2,0); XCTAssertEqual(g.outWidth%2,0)
        edit.crop=CGRect(x:0,y:0,width:0.02,height:0.02)
        let small=edit.geometry(for:info)
        XCTAssertLessThanOrEqual(small.outWidth,small.width); XCTAssertLessThanOrEqual(small.outHeight,small.height)
    }
    func testTimeParsingAndFormatting() {
        XCTAssertEqual(TimeText.parse("01:02:03.450"),3723.45)
        XCTAssertEqual(TimeText.parse("0.5"),0.5)
        XCTAssertNil(TimeText.parse("nan")); XCTAssertNil(TimeText.parse("-1"))
        XCTAssertEqual(TimeText.format(3723.45),"01:02:03.450")
    }
    func testRotationRead() throws {
        let m=try open(fixture("rotated.mp4")); defer { clip_close(m) }
        let info=clip_info(m)
        XCTAssertEqual(abs(info.rotation),90,accuracy:0.1)
        XCTAssertEqual(details(info).displaySize.width,90)
        XCTAssertEqual(details(info).displaySize.height,160)
    }
}
