import AppKit
import SwiftUI

/// This build's own `typemeit-mcp`, and Claude Code's entry for it, which is
/// written through Claude Code's own CLI when the user asks; nothing here
/// edits another app's files.
enum MCPSetup {
    /// The bundled binary, at this build's own path, so the dev app copies its own.
    static let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/typemeit-mcp")
    /// The server's name in an assistant's config.
    static let name = "typemeit"
    /// `claude mcp get` starts the server to check it, so a hung one is given this long.
    static let claudeTimeoutSeconds = 20.0
    /// Gatekeeper runs a quarantined app from a random path that is gone on
    /// the next launch, so a command naming it would break (docs/meetings.md 7.15).
    static let translocated = Bundle.main.bundlePath.contains("/AppTranslocation/")

}

/// Whether Claude Code has the meetings server, and whether it names this
/// copy of the app or another one, such as the release app seen from a dev build.
enum ClaudeCodeMCPStatus: Sendable {
    case missing, thisCopy, otherCopy
}

extension MCPSetup {
    /// Nil when Claude Code could not be asked.
    static func claudeCodeStatus() async -> ClaudeCodeMCPStatus? {
        guard let get = await claude(["mcp", "get", name]) else { return nil }
        guard get.status == 0 else { return .missing }
        return get.output.contains(binary.path) ? .thisCopy : .otherCopy
    }

    /// Adds this copy's server to Claude Code for every project, first
    /// removing one that names another copy.
    static func addToClaudeCode(replacing: Bool) async -> Bool {
        if replacing { _ = await claude(["mcp", "remove", name, "--scope", "user"]) }
        let add = await claude(["mcp", "add", "--scope", "user", name, "--", binary.path])
        DebugLog.write("MCP: claude mcp add \(add?.status == 0 ? "succeeded" : "failed"): \(add?.output.prefix(300) ?? "claude did not start")")
        return add?.status == 0
    }

    /// Runs `claude` and waits for it; nil when Claude Code is not available
    /// or did not start.
    private static func claude(_ arguments: [String]) async -> (status: Int32, output: String)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let claude = ClaudeRun.command(arguments, withErrors: true, timeoutSeconds: claudeTimeoutSeconds) else {
                    return continuation.resume(returning: nil)
                }
                try? claude.input.close()
                let output = claude.output.readDataToEndOfFile()
                claude.process.waitUntilExit()
                continuation.resume(returning: (claude.process.terminationStatus, String(decoding: output, as: UTF8.self)))
            }
        }
    }
}

/// "add to claude code", which runs `claude mcp add`, or "added to claude
/// code" once Claude Code names this copy; "install" without Claude Code.
struct MCPAddToClaudeCode: View {
    enum Row: Equatable {
        case checking
        /// Claude Code could not be asked: not installed, or it did not start.
        case unreachable
        /// Claude Code has no server for this copy; `replacing` when it names another copy.
        case absent(replacing: Bool, adding: Adding)
        case added

        enum Adding: Equatable { case notYet, running, failed }

        /// What Claude Code answered, or nil when it could not be asked.
        init(_ status: ClaudeCodeMCPStatus?) {
            switch status {
            case nil: self = .unreachable
            case .missing: self = .absent(replacing: false, adding: .notYet)
            case .otherCopy: self = .absent(replacing: true, adding: .notYet)
            case .thisCopy: self = .added
            }
        }
    }

    /// What the row's task asks again for: Claude Code coming or going, or a retry.
    private struct Ask: Hashable {
        let claudeAvailable: Bool
        let retries: Int
    }

    @State private var row = Row.checking
    @State private var retries = 0

    var body: some View {
        // A stack, not a Group: a Group with nothing in it yet would never
        // appear, and its task would never ask.
        HStack(spacing: 10) {
            switch row {
            case .added:
                Text("added to claude code").font(Square.mono(12)).foregroundStyle(DesignTokens.Colors.ink2)
            case .absent(let replacing, .failed):
                Text("couldn’t add").font(Square.sans(11.5)).foregroundStyle(DesignTokens.Colors.ink2)
                Button("retry") { add(replacing: replacing) }.buttonStyle(SquareButtonStyle(small: true))
            case .absent(let replacing, let adding):
                Button(adding == .running ? "adding…" : "add to claude code") { add(replacing: replacing) }
                    .buttonStyle(SquareButtonStyle(small: true))
                    .disabled(adding == .running)
            case .checking:
                if ClaudeRun.isAvailable { SquareSpinner() } else { installButton }
            case .unreachable:
                if ClaudeRun.isAvailable {
                    Button("retry") { retries += 1 }.buttonStyle(SquareButtonStyle(small: true))
                } else {
                    installButton
                }
            }
        }
        .task(id: Ask(claudeAvailable: ClaudeRun.isAvailable, retries: retries)) {
            row = .checking
            row = Row(await MCPSetup.claudeCodeStatus())
        }
    }

    private var installButton: some View {
        Button("install") { NSWorkspace.shared.open(ClaudeRun.installPage) }.buttonStyle(SquareButtonStyle(small: true))
    }

    private func add(replacing: Bool) {
        row = .absent(replacing: replacing, adding: .running)
        Task {
            let added = await MCPSetup.addToClaudeCode(replacing: replacing)
            row = added ? .added : .absent(replacing: replacing, adding: .failed)
        }
    }
}

/// The server's tools by name, each explained on hover. MCPTests checks the
/// names against the server's tools/list, which this target can't import.
struct MCPToolList: View {
    static let tools: [(name: String, help: String)] = [
        ("list_meetings", "lists your meetings, newest first · titles, dates and people, no transcripts"),
        ("get_meeting", "reads one meeting's transcript"),
        ("search_meetings", "finds a phrase in your meeting transcripts"),
        ("meeting_stats", "counts meetings, hours and talk time per person over a date range"),
        ("edit_meeting", "changes a meeting's title or summary"),
        ("list_dictations", "lists your dictations, newest first · the text and the app it went into"),
        ("search_dictations", "finds a phrase in your dictations"),
        ("list_hooks", "lists your hooks"),
        ("add_hook", "adds a hook · it stays off until you switch it on here"),
        ("update_hook", "changes a hook's name or prompt · switches it off until you switch it on again"),
        ("remove_hook", "deletes a hook"),
        ("get_system_prompt", "reads the system prompt claude code gets from this app"),
        ("update_system_prompt", "replaces that system prompt"),
    ]
    @State private var settings = Settings.shared

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Self.tools, id: \.name) { tool in
                let off = settings.mcpOffTools.contains(tool.name)
                SquareHelpChip(text: tool.name, help: off ? "off · click to switch on" : tool.help, off: off) {
                    if off { settings.mcpOffTools.removeAll { $0 == tool.name } } else { settings.mcpOffTools.append(tool.name) }
                }
            }
        }
    }
}
