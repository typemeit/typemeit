// swift-tools-version: 6.0
import PackageDescription

// The app's own EchoFold, EchoLag and EchoBleedDetector over AssemblyAI word timings, to measure what the
// shipped echo handling leaves on the mic track. Sources are copied from TypeMeIt/Meetings by run.sh.
let package = Package(
    name: "echofold",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "echofold", path: "Sources/echofold", swiftSettings: [.swiftLanguageMode(.v5)])]
)
