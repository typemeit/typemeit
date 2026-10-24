// swift-tools-version: 6.0
import PackageDescription

// Prints a diarizer's turns for one 16 kHz WAV as JSON: [{"startMs","endMs","speaker"}].
// usage: diar <nemotron|lseend-ami|lseend-callhome|lseend-dihard3> <audio.wav>
// run.sh copies the app's SpeakerFrames.swift in and generates Stubs.swift from Settings.swift.
let package = Package(
    name: "diar",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5")],
    targets: [
        .executableTarget(name: "diar", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/diar", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
