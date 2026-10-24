// swift-tools-version: 6.0
import PackageDescription

// Transcribes WAV files with Qwen3-ASR-0.6B (Core ML). FluidAudio removed this backend after v0.15.2
// (PR #676), so this package pins that tag; the app's FluidAudio (0.17.x) cannot load it.
// usage: qwen3asr <f32|int8> <dictation|meeting> <items.json> <out.json>
let package = Package(
    name: "qwen3asr",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.2")],
    targets: [
        .executableTarget(name: "qwen3asr", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/qwen3asr", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
