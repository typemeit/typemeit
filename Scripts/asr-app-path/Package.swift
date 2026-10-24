// swift-tools-version: 6.0
import PackageDescription

// Runs the app's own Transcriber (and the meeting chunk loop around it) on WAV files.
// run.sh copies the app's sources in and generates Sources/appasr/Stubs.swift; build with it.
let package = Package(
    name: "appasr",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.6")],
    targets: [
        .executableTarget(name: "appasr", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/appasr", swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-enable-bare-slash-regex"])]),
    ]
)
