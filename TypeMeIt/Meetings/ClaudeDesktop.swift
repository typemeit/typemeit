import AppKit

/// Hands a Claude Code run to the Claude desktop app: a new Code session in
/// the folder Claude runs from here, with a prompt typed in and not sent.
@MainActor
enum ClaudeDesktop {
    /// Whether an app on this Mac opens claude:// links.
    static var installed: Bool {
        URL(string: "claude://").flatMap(NSWorkspace.shared.urlForApplication(toOpen:)) != nil
    }

    static func open(prompt: String) {
        var link = URLComponents()
        link.scheme = "claude"
        link.host = "code"
        link.path = "/new"
        link.queryItems = [URLQueryItem(name: "folder", value: Settings.shared.askClaudeFolder),
                           URLQueryItem(name: "q", value: prompt)]
        if let url = link.url { NSWorkspace.shared.open(url) }
    }

    /// The meeting tool the prompt names when Claude Code can reach this copy's server.
    private static let meetingTool = "get_meeting"

    /// Names the session by its log when Claude Code kept one, and the
    /// meeting it ran on, if any: by id when Claude Code can call this copy's
    /// meeting tool, otherwise by the meeting's transcript file.
    static func prompt(resuming sessionID: String, meeting: UUID?) -> String {
        let session = transcript(sessionID).map { "Pick up the Claude Code session at \($0.path)." }
            ?? "Pick up Claude Code session \(sessionID)."
        guard let meeting else { return session }
        if meetingToolReachable() {
            return "\(session) It ran on meeting \(meeting.uuidString); read that with the \(MCPSetup.name) \(meetingTool) tool."
        }
        guard let folder = MeetingStore.shared.folder(for: meeting) else { return session }
        return "\(session) The meeting's transcript is \(folder.appendingPathComponent(SupportPaths.transcriptFile).path)."
    }

    private static func meetingToolReachable() -> Bool {
        let settings = Settings.shared
        guard settings.mcpEnabled, !settings.mcpOffTools.contains(meetingTool) else { return false }
        return userServerCommand() == MCPSetup.binary.path
    }

    /// The part of Claude Code's `~/.claude.json` read here: the servers
    /// added for every project, where `MCPSetup.addToClaudeCode` puts ours.
    private struct ClaudeConfig: Decodable {
        struct Server: Decodable { let command: String? }
        let mcpServers: [String: Server]?
    }

    /// The command Claude Code starts for our server, read from its config
    /// file rather than `claude mcp get`, which starts the server to check it.
    private static func userServerCommand() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let config = try? JSONDecoder().decode(ClaudeConfig.self, from: data) else { return nil }
        return config.mcpServers?[MCPSetup.name]?.command
    }

    /// The session's transcript in whichever of Claude Code's project folders
    /// holds it, since `askClaudeFolder` may have changed since the run.
    private static func transcript(_ sessionID: String) -> URL? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent("\(sessionID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
