// swift-tools-version: 5.10
// 5.10 keeps every target in Swift 5 language mode, matching SWIFT_VERSION in project.yml.
import PackageDescription

let package = Package(
    name: "Sketchpad",
    platforms: [.macOS(.v14)],
    targets: [
        // Pixel model and raster algorithms; no AppKit, so it can be unit tested headlessly.
        .target(name: "PaintCore"),
        .executableTarget(name: "Sketchpad", dependencies: ["PaintCore"]),
        .testTarget(name: "PaintCoreTests", dependencies: ["PaintCore"]),
    ]
)
