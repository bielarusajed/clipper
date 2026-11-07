// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendor = root + "/.build/media"
let package = Package(
    name: "Clipper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Clipper", targets: ["Clipper"])],
    targets: [
        .target(name: "CMedia", path: "Sources/CMedia", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I" + vendor + "/include"])],
                linkerSettings: [.unsafeFlags(["-L" + vendor + "/lib", "-lass", "-lavformat", "-lavcodec", "-lavutil", "-lswscale", "-lswresample"]),
                                 .linkedFramework("AVFoundation"), .linkedFramework("VideoToolbox"), .linkedFramework("CoreImage")]),
        .executableTarget(name: "Clipper", dependencies: ["CMedia"],
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", vendor + "/lib"])]),
        .testTarget(name: "ClipperTests", dependencies: ["Clipper"])
    ]
)
