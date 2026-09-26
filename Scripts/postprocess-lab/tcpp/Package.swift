// swift-tools-version: 5.9
import PackageDescription

// Transcribes the same item lists with the app's own Transcriber (transcribe.cpp,
// parakeet-unified Q8_0 GGUF on Metal), timing each call.
let package = Package(
    name: "tcpp",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../Packages/TranscribeCpp")],
    targets: [.executableTarget(name: "tcpp", dependencies: ["TranscribeCpp"], path: "Sources/tcpp", swiftSettings: [.unsafeFlags(["-enable-bare-slash-regex"])])]
)
