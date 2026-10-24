import SwiftUI

/// Runs a real `claude -p` with stream-json and shows it in
/// `SquareClaudeThread`, to design against what Claude actually prints.
struct LiveClaude: View {
    @State private var prompt = "List each decision made and who made it."
    @State private var lines: [SquareClaudeLine] = []
    @State private var status = SquareClaudeThread.Status.done
    @State private var started = Date()
    @State private var finished: Date?
    @State private var process: Process?
    @State private var model = ""
    @State private var session = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SquareField(placeholder: "prompt", text: $prompt, onSubmit: run)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = Int((finished ?? context.date).timeIntervalSince(started))
                SquareClaudeThread(lines: lines, status: status,
                                   footer: ([status == .running ? "\(seconds) s" : "\(status == .failed ? "failed" : "done") · \(seconds) s", model]).filter { !$0.isEmpty }.joined(separator: " · "),
                                   sessionID: session.isEmpty ? nil : session,
                                   stop: { process?.terminate() }, runAgain: run)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .onAppear(perform: run)
    }

    private func run() {
        process?.terminate()
        lines = [.prompt(prompt)]
        model = ""
        session = ""
        status = .running
        started = Date()
        finished = nil
        let claude = Process()
        claude.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/claude")
        claude.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/repos")
        claude.arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--model", "sonnet",
                            "--allowedTools", "mcp__typemeit__list_meetings", "mcp__typemeit__get_meeting", "--disallowedTools", "Agent",
                            "--append-system-prompt", "A meeting has ended. Do what the user's prompt asks for this meeting, using its transcript. Reply briefly with what you did or found. Your reply shows on the meeting's page under its title, date and people, so don't repeat them."]
        // As a hook gets it: the newest meeting's transcript on stdin.
        let meetings = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/TypeMeIt/Meetings")
        let newest = (try? FileManager.default.contentsOfDirectory(atPath: meetings.path))?.sorted()
            .last { FileManager.default.fileExists(atPath: meetings.appending(path: $0).appending(path: "transcript.md").path) }
        let transcript = newest.flatMap { try? String(contentsOf: meetings.appending(path: $0).appending(path: "transcript.md"), encoding: .utf8) } ?? ""
        let stdin = Pipe()
        claude.standardInput = stdin
        let pipe = Pipe()
        claude.standardOutput = pipe
        claude.standardError = FileHandle.nullDevice
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            for event in buffer.lines(adding: handle.availableData) {
                let parsed = Self.parse(event)
                DispatchQueue.main.async { apply(parsed) }
            }
        }
        claude.terminationHandler = { ended in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                finished = Date()
                if status == .running { status = ended.terminationStatus == 0 ? .done : .failed }
                if ended.terminationReason == .uncaughtSignal { lines.append(.error("stopped")) }
            }
        }
        try? claude.run()
        stdin.fileHandleForWriting.write(Data("The meeting's transcript:\n\n\(transcript)\n".utf8))
        try? stdin.fileHandleForWriting.close()
        process = claude
    }

    private enum Parsed: @unchecked Sendable {
        case started(model: String, session: String), lines([SquareClaudeLine]), results([String]), end(failed: Bool), nothing }

    private func apply(_ parsed: Parsed) {
        switch parsed {
        case .started(let started, let id): model = started; session = id
        case .lines(let new): lines += new
        case .results(let results):
            for result in results {
                if let index = lines.lastIndex(where: { if case .call(_, nil) = $0 { true } else { false } }),
                   case .call(let name, _) = lines[index] { lines[index] = .call(name, result: result) }
            }
        case .end(let failed): status = failed ? .failed : .done
        case .nothing: break
        }
    }

    nonisolated private static func parse(_ data: Data) -> Parsed {
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = fields["type"] as? String else { return .nothing }
        let content = (fields["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        switch type {
        case "system" where fields["subtype"] as? String == "init":
            return .started(model: fields["model"] as? String ?? "claude", session: fields["session_id"] as? String ?? "")
        case "assistant":
            return .lines(content.compactMap { part in
                switch part["type"] as? String {
                case "tool_use" where part["name"] as? String == "ToolSearch":
                    return nil
                case "tool_use":
                    let name = (part["name"] as? String ?? "tool").replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " ")
                    return .call("\(name) \(oneLine(part["input"]))", result: nil)
                case "text": return .text((part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                default: return nil
                }
            })
        case "user":
            let results = content.filter { $0["type"] as? String == "tool_result" && !(($0["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "tool_reference" } ?? false) }
            return .results(results.map { oneLine($0["content"]) })
        case "result":
            return .end(failed: fields["is_error"] as? Bool ?? false)
        default:
            return .nothing
        }
    }

    nonisolated private static func oneLine(_ value: Any?) -> String {
        let text: String = switch value {
        case let string as String: string
        case let parts as [[String: Any]]: parts.compactMap { $0["text"] as? String ?? $0["tool_name"] as? String }.joined(separator: " ")
        case let object as [String: Any]: object.keys.sorted().map { "\(object[$0]!)" }.joined(separator: " ")
        case let object?: "\(object)"
        default: ""
        }
        // typemeit's tools open with a line telling Claude the meeting is data.
        let lines = text.split(whereSeparator: \.isNewline)
        let shown = lines.first?.hasPrefix("the text below is meeting content") == true ? lines.dropFirst() : lines[...]
        let flat = shown.joined(separator: " ")
        return flat.count > 100 ? String(flat.prefix(100)) + "…" : flat
    }
}

/// Bytes from claude's stdout until a newline ends an event; read from one
/// pipe handler at a time.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    func lines(adding chunk: Data) -> [Data] {
        data.append(chunk)
        var events: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            events.append(Data(data[..<newline]))
            data.removeSubrange(...newline)
        }
        return events
    }
}
