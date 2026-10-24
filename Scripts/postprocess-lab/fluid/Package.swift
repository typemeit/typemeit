// swift-tools-version: 6.0
import PackageDescription

// Transcribes audio with FluidAudio's parakeet-unified (CoreML): batch, with and
// without per-call vocabulary boosting (fluidtest), and streamed (fluidstream).
let package = Package(
    name: "fluidtest",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4")],
    targets: [
        .executableTarget(name: "fluidtest", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/fluidtest"),
        .executableTarget(name: "fluidstream", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/fluidstream", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
