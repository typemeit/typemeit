import Foundation

// The MCP stdio entry point (docs/meetings.md 7.15): reads JSON-RPC requests
// from stdin one line at a time and writes replies to stdout. Diagnostics go
// to stderr; stdout carries only JSON-RPC. `MCPServer.handle` never traps on
// bad input, and neither does this loop — a read or decode failure just
// produces an error reply or is skipped, not a crash.

/// `~/Library/Application Support/TypeMeIt`, or `TYPEMEIT_SUPPORT_DIR` when
/// set. Mirrors `Store.directory` (TypeMeIt/Store.swift), which this target
/// does not share.
private func supportDirectory() -> URL {
    if let dir = ProcessInfo.processInfo.environment["TYPEMEIT_SUPPORT_DIR"] {
        return URL(fileURLWithPath: dir, isDirectory: true)
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("TypeMeIt", isDirectory: true)
}

/// The bundle id of the `.app` two directories above this executable
/// (`Contents/MacOS/typemeit-mcp`), so the switch reads the same
/// `UserDefaults` domain the host app's `UserDefaults.standard` does.
private func hostBundleID() -> String? {
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let appURL = executableURL
        .deletingLastPathComponent() // MacOS
        .deletingLastPathComponent() // Contents
        .deletingLastPathComponent() // the .app
    return Bundle(url: appURL)?.bundleIdentifier
}

private func writeStandardOut(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

private func writeStandardError(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// `UserDefaults(suiteName:)` with the *calling process's own* bundle id is
/// documented by Foundation as nonsensical and silently does not read the
/// persisted domain — and this process's own `Bundle.main` already resolves
/// to the enclosing `.app` (Foundation walks up from an executable inside
/// `Contents/MacOS` to find it), so it equals `bundleID` on every real launch
/// of this tool. `.standard` is what actually reads that domain in that case;
/// the suite form is kept only as a fallback for some other embedding this
/// binary is not built for.
private func hostDefaults(bundleID: String) -> UserDefaults? {
    if Bundle.main.bundleIdentifier == bundleID {
        return .standard
    }
    return UserDefaults(suiteName: bundleID)
}

/// Whether the switch is on, and which folder to read, read fresh so a
/// setting change in the app takes effect without restarting this process
/// (docs/meetings.md 7.15).
private func meetingsDefaults(bundleID: String?) -> (enabled: Bool, root: URL) {
    let fallbackRoot = supportDirectory().appendingPathComponent("Meetings", isDirectory: true)
    guard let bundleID, let defaults = hostDefaults(bundleID: bundleID) else {
        return (false, fallbackRoot)
    }
    let enabled = defaults.bool(forKey: "meetingsMCP")
    let root = defaults.string(forKey: "meetingsFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fallbackRoot
    return (enabled, root)
}

let bundleID = hostBundleID()
if bundleID == nil {
    writeStandardError("typemeit-mcp: could not find the host app's bundle id; meetings mcp will read as off")
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    let (enabled, root) = meetingsDefaults(bundleID: bundleID)
    if let reply = MCPServer.handle(line, root: root, enabled: enabled) {
        writeStandardOut(reply)
    }
}
