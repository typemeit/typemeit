// swift-tools-version: 6.0
import PackageDescription

// Transcribes WAV files with FluidAudio's Parakeet-family Core ML models (ultra, phonon2, or a local
// v3-layout folder in FLUIDASR_MODEL_DIR, or Bark 3.0 Pro's Core ML folder there).
// usage: fluidasr <ultra|phonon2|unified|local|bark-pro> <items.json> <out.json>
let package = Package(
    name: "fluidasr",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5")],
    targets: [
        .executableTarget(name: "fluidasr", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/fluidasr", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
