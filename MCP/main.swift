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

/// Whether the switch is on, read fresh so a setting change in the app
/// takes effect without restarting this process (docs/meetings.md 7.15).
/// The key is named for meetings, which it once covered alone.
private func mcpEnabled(bundleID: String?) -> Bool {
    guard let bundleID, let defaults = hostDefaults(bundleID: bundleID) else { return false }
    return defaults.bool(forKey: "meetingsMCP")
}

let bundleID = hostBundleID()
if bundleID == nil {
    writeStandardError("typemeit-mcp: could not find the host app's bundle id; mcp will read as off")
}
let meetingsRoot = supportDirectory().appendingPathComponent("Meetings", isDirectory: true)
/// The app's hooks, read and written in its own UserDefaults; the app
/// observes the key, so a write shows in its settings at once.
let hookStore = MCPTools.HookStore(
    read: {
        guard let bundleID, let defaults = hostDefaults(bundleID: bundleID),
              let stored = defaults.data(forKey: MeetingHook.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([MeetingHook].self, from: stored)) ?? []
    },
    write: { hooks in
        guard let bundleID, let defaults = hostDefaults(bundleID: bundleID) else { return }
        defaults.set(try? JSONEncoder().encode(hooks), forKey: MeetingHook.defaultsKey)
    })
let systemPromptStore = MCPTools.PromptStore(
    read: { bundleID.flatMap { hostDefaults(bundleID: $0)?.string(forKey: MCPDefaults.systemPromptKey) } ?? "" },
    write: { prompt in
        guard let bundleID else { return }
        hostDefaults(bundleID: bundleID)?.set(prompt, forKey: MCPDefaults.systemPromptKey)
    })
/// Tools the user switched off, read fresh like the switch.
private func offTools(bundleID: String?) -> Set<String> {
    Set(bundleID.flatMap { hostDefaults(bundleID: $0)?.stringArray(forKey: MCPDefaults.offToolsKey) } ?? [])
}
/// Mirrors `Store`'s `historyURL` (TypeMeIt/Store.swift).
let historyFile = supportDirectory().appendingPathComponent("history.json")

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    if let reply = MCPServer.handle(line, root: meetingsRoot, history: historyFile, hooks: hookStore, enabled: mcpEnabled(bundleID: bundleID),
                                    systemPrompt: systemPromptStore, off: offTools(bundleID: bundleID)) {
        writeStandardOut(reply)
    }
}
