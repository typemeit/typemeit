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
            for line in buffer.lines(adding: handle.availableData) {
                guard let event = ClaudeStream.event(for: String(decoding: line, as: UTF8.self)) else { continue }
                DispatchQueue.main.async { apply(event) }
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

    private func apply(_ event: ClaudeStream.Event) {
        switch event {
        case .started(let started, let id): model = started; session = id ?? ""
        case .lines(let new): lines += new
        case .results(let results): lines = ClaudeStream.filling(lines, with: results)
        case .ended(_, let failed): status = failed ? .failed : .done
        }
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
