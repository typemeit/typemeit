// swift-tools-version: 6.0
import PackageDescription

// Runs FluidAudio's LocalVQE echo canceller over a mic track with the far-end track as reference.
// usage: vqe <mic.wav> <reference.wav> <out.wav>   (prints one JSON line of timing)
let package = Package(
    name: "vqe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5")],
    targets: [
        .executableTarget(name: "vqe", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/vqe", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
