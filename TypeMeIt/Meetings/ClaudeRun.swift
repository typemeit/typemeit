import Foundation

/// One headless Claude Code run (`claude -p`). `answering` is the run on a
/// question asked in a meeting, `hook` the run of a hook on a finished one: it loads the user's own setup, MCP servers
/// included, from the folder it runs in, with the meeting's transcript so far
/// on stdin, in auto mode: a classifier reviews each action and blocks
/// anything beyond the request, and with no terminal to ask in, a blocked
/// action is skipped and Claude carries on.
final class ClaudeRun: @unchecked Sendable {
    struct Answer: Sendable, Equatable {
        let text: String
        let seconds: Double
        let costUSD: Double?
        let failed: Bool
        /// What `claude --resume` takes to pick the run up again.
        var sessionID: String? = nil
        /// What Claude Code says it ran with; nil when it printed no start event.
        var setup: Setup? = nil
    }

    /// The run's start event and the result's thinking count, which
    /// `ClaudeCheck` holds against the flags the run was given.
    struct Setup: Sendable, Equatable {
        var version: String?
        var permissionMode: String?
        var model: String?
        var tools: [String] = []
        var mcpServers: [String] = []
        /// Nil when the result does not report it.
        var thinkingTokens: Int?
    }

    /// `--permission-mode` choices that run without anyone to answer a
    /// prompt, with what each lets Claude do. "manual" waits for answers a
    /// headless run never gets.
    static let permissionModes: [(mode: String, caption: String)] = [
        ("auto", "a classifier reviews each action"),
        ("plan", "reads only, changes nothing"),
        ("dontAsk", "only tools allowed in settings, nothing else"),
        ("acceptEdits", "edits files without asking"),
        ("bypassPermissions", "does anything, with no checks"),
    ]

    /// Claude Code's own default, whatever the plan makes it; no `--model`.
    static let defaultModel = "default"
    static let answerTimeoutSeconds = 180.0
    /// A hook can do more than look something up, such as writing tickets.
    static let hookTimeoutSeconds = 600.0

    private static let instructions = """
        Answer the latest question asked in a live meeting, using the speech-recognised \
        transcript for context; earlier questions in it are not yours to answer. Look it up \
        without changing anything. Answer in one or two sentences, then say \
        where it came from.
        """

    /// A question dictated with no meeting recording: there is no transcript,
    /// and speech recognition can mishear a word, most often a name.
    private static let spokenInstructions = """
        Answer a question the user asked out loud. It was speech-recognised, so a word may \
        be misheard; read it as the user most likely meant it. Look it up without changing \
        anything. Answer in one or two sentences, then say where it came from.
        """

    private static let hookInstructions = """
        A meeting has ended. Do what the user's prompt asks for this meeting, using its \
        transcript. Reply briefly with what you did or found. Your reply shows on the \
        meeting's page under its title, date and people, so don't repeat them.
        """

    /// The reply renders as GitHub-flavoured Markdown in a small panel
    /// (`ClaudeMarkdown`). An ASCII table that comes back anyway still
    /// renders as a table (`ClaudeReplyMarkdown`).
    private static let formatting = """
        Your reply shows in a small panel in the app, rendered as GitHub-flavoured Markdown. \
        Write only valid Markdown: bold, italics, links, inline code, lists and tables. Put a \
        table in Markdown table syntax, never drawn with ASCII or box-drawing characters. Put \
        a diagram in a ``` block. Use no headings.
        """

    /// Where Claude Code installs itself, then where Homebrew puts it. An app
    /// opened from the Finder does not get the shell's PATH, so it is not searched.
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static let installPage = URL(string: "https://claude.com/claude-code")!

    /// The `claude` this build may run: the installed one, never from a
    /// sandboxed build.
    static func availableExecutable(sandboxed: Bool = Sandbox.isActive, installed: URL? = executable) -> URL? {
        sandboxed ? nil : installed
    }

    /// Claude Code is installed and this build may run it; a sandboxed one cannot.
    static var isAvailable: Bool { availableExecutable() != nil }

    /// The login shell's PATH, so the MCP servers Claude Code starts (npx, uv,
    /// bq…) are found the way they are in a terminal.
    private static let loginPath: String = {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return "/usr/bin:/bin:/usr/sbin:/sbin" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }()

    /// The app's environment for a `claude` it starts. A dev build launched
    /// from inside a Claude Code session inherits that session's auth
    /// variables, which a separate `claude` cannot use, so they are dropped.
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("CLAUDE") && !key.hasPrefix("ANTHROPIC")
        }
        environment["PATH"] = loginPath
        return environment
    }

    private let process = Process()
    private let input: Data
    private let timeoutSeconds: Double
    /// Each line of output as it arrives, on a background thread.
    var onLine: (@Sendable (String) -> Void)?

    /// Nil when Claude Code is not available.
    init?(arguments: [String], input: String, folder: URL, timeoutSeconds: Double, extraEnvironment: [String: String] = [:]) {
        guard let executable = Self.availableExecutable() else { return nil }
        process.executableURL = executable
        process.currentDirectoryURL = folder
        process.arguments = arguments
        process.environment = Self.environment.merging(extraEnvironment) { _, extra in extra }
        self.input = Data(input.utf8)
        self.timeoutSeconds = timeoutSeconds
    }

    /// A short `claude` command, such as `claude mcp get`, and its pipes.
    struct Command {
        let process: Process
        let input: FileHandle
        /// Its stdout, with stderr when `withErrors`.
        let output: FileHandle
    }

    /// Starts `executable` with `arguments` in the home folder with
    /// `environment`, and ends it after `timeoutSeconds`. Nil when Claude
    /// Code is not available or did not start.
    static func command(_ arguments: [String], withErrors: Bool = false, timeoutSeconds: Double, executable: URL? = availableExecutable()) -> Command? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = withErrors ? stdout : FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { if process.isRunning { process.terminate() } }
        return Command(process: process, input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading)
    }

    /// `transcript` is the meeting's so far, or nil for a question dictated
    /// with no meeting recording.
    static func answering(prompt: String, transcript: String?, folder: URL, model: String, allowedTools: [String], permissionMode: String, userSystemPrompt: String) -> ClaudeRun? {
        ClaudeRun(arguments: arguments(prompt: prompt, instructions: transcript == nil ? spokenInstructions : instructions, model: model,
                                       allowedTools: allowedTools, permissionMode: permissionMode, userSystemPrompt: userSystemPrompt),
                  input: transcript.map { "The meeting's transcript so far:\n\n\($0)\n" } ?? "", folder: folder, timeoutSeconds: answerTimeoutSeconds)
    }

    static let questionModel = "haiku"
    /// Left out of `answering` and `hook`: a background agent ends the run with a
    /// second turn whose result replaces the answer ("Already reported").
    static let disallowedTool = "Agent"

    /// Haiku with no tools, MCP servers, settings, Claude Code system prompt or thinking, which writes out the
    /// transcript's latest question for `answering` to take. Thinking made it 4–6 s
    /// of model time against about 1 s without, for the same question.
    static func latestQuestion(in transcript: String) -> ClaudeRun? {
        ClaudeRun(arguments: ["-p", "Write out the latest question asked in this meeting transcript as one standalone question, with any context it needs from earlier. Reply with the question only.",
                              "--output-format", "stream-json", "--verbose", "--model", questionModel,
                              "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
                              "--disable-slash-commands", "--system-prompt", "You extract questions from transcripts."],
                  input: transcript, folder: FileManager.default.temporaryDirectory, timeoutSeconds: answerTimeoutSeconds,
                  extraEnvironment: ["MAX_THINKING_TOKENS": "0"])
    }

    /// `transcript` is the meeting's whole Markdown transcript.
    static func hook(prompt: String, transcript: String, folder: URL, model: String, allowedTools: [String], permissionMode: String, userSystemPrompt: String) -> ClaudeRun? {
        ClaudeRun(arguments: arguments(prompt: prompt, instructions: hookInstructions, model: model, allowedTools: allowedTools,
                                       permissionMode: permissionMode, userSystemPrompt: userSystemPrompt),
                  input: "The meeting's transcript:\n\n\(transcript)\n", folder: folder, timeoutSeconds: hookTimeoutSeconds)
    }

    static let testPrompt = "Reply with the code from your instructions."

    /// A run with the user's folder, model, permissions and system prompt
    /// that only replies with `code`, which reaches Claude only through the
    /// appended system prompt, so a reply without it means that was dropped.
    static func test(code: String, folder: URL, model: String, allowedTools: [String], permissionMode: String, userSystemPrompt: String) -> ClaudeRun? {
        ClaudeRun(arguments: arguments(prompt: testPrompt, instructions: "Check that Claude Code runs. Use no tools. Reply with the code \(code) and nothing else.",
                                       model: model, allowedTools: allowedTools, permissionMode: permissionMode, userSystemPrompt: userSystemPrompt),
                  input: "", folder: folder, timeoutSeconds: answerTimeoutSeconds)
    }

    private static func arguments(prompt: String, instructions: String, model: String, allowedTools: [String], permissionMode: String, userSystemPrompt: String) -> [String] {
        let trimmed = userSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = [instructions, formatting, trimmed].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return ["-p", prompt,
                "--output-format", "stream-json", "--verbose",
                "--permission-mode", permissionMode,
                "--append-system-prompt", systemPrompt,
                "--disallowedTools", disallowedTool]
            + (model == defaultModel ? [] : ["--model", model])
            + (allowedTools.isEmpty ? [] : ["--allowedTools"] + allowedTools)
    }

    func answer() async -> Answer {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.runToEnd())
            }
        }
    }

    /// Ends the turn the way Ctrl-C does, so Claude Code stops cleanly.
    func cancel() {
        if process.isRunning { process.interrupt() }
    }

    private func runToEnd() -> Answer {
        let started = ContinuousClock.now
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return Answer(text: "Claude Code did not start: \(error.localizedDescription)", seconds: 0, costUSD: nil, failed: true)
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in self?.cancel() }

        var errorData = Data()
        let errorRead = DispatchGroup()
        errorRead.enter()
        DispatchQueue.global().async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            errorRead.leave()
        }
        // Read as it comes, so `onLine` sees each event while Claude works.
        var outputData = Data()
        var partLine = Data()
        while true {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            outputData.append(chunk)
            guard let onLine else { continue }
            partLine.append(chunk)
            while let newline = partLine.firstIndex(of: UInt8(ascii: "\n")) {
                onLine(String(decoding: partLine[partLine.startIndex..<newline], as: UTF8.self))
                partLine = Data(partLine[partLine.index(after: newline)...])
            }
        }
        errorRead.wait()
        process.waitUntilExit()
        let seconds = (ContinuousClock.now - started).timeInSeconds
        Self.keepLog(arguments: process.arguments ?? [], input: input, output: outputData, errors: errorData,
                     exitStatus: process.terminationStatus, seconds: seconds)
        DebugLog.write("Claude run: exit \(process.terminationStatus) after \(String(format: "%.1f", seconds)) s, \(counted(outputData.count, "byte")) out, stderr \(String(decoding: errorData.prefix(300), as: UTF8.self))")
        return Self.parse(outputData, errors: errorData, seconds: seconds, exitStatus: process.terminationStatus)
    }

    /// Where every run's full output is kept, whether or not debug logs are on.
    static let logFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/TypeMeIt/claude")

    /// Writes the run's arguments, input, every streamed event and stderr to
    /// one file per run, named for when it ended and unique, since hooks can
    /// end in the same second.
    private static func keepLog(arguments: [String], input: Data, output: Data, errors: Data, exitStatus: Int32, seconds: Double) {
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "") + "-\(UUID().uuidString).log"
        let header = "exit \(exitStatus) after \(String(format: "%.1f", seconds)) s\nclaude \(arguments.joined(separator: " "))\n\n--- stdin\n"
        var log = Data(header.utf8)
        log.append(input)
        log.append(Data("\n--- stdout\n".utf8))
        log.append(output)
        log.append(Data("\n--- stderr\n".utf8))
        log.append(errors)
        try? FileManager.default.createDirectory(at: logFolder, withIntermediateDirectories: true)
        try? log.write(to: logFolder.appending(path: name))
    }

    /// The run's answer. A failed run's answer is Claude Code's own error:
    /// the result's text or `errors`, else what it printed to stderr, so the
    /// run's output shows why it failed.
    static func parse(_ output: Data, errors: Data = Data(), seconds: Double, exitStatus: Int32) -> Answer {
        struct Usage: Decodable {
            struct Details: Decodable { let thinking_tokens: Int? }
            let output_tokens_details: Details?
        }
        struct MCPServer: Decodable { let name: String }
        struct Result: Decodable {
            let type: String
            let subtype: String?
            let result: String?
            let is_error: Bool?
            let errors: [String]?
            let total_cost_usd: Double?
            let session_id: String?
            let usage: Usage?
            // The start event's.
            let claude_code_version: String?
            let permissionMode: String?
            let model: String?
            let tools: [String]?
            let mcp_servers: [MCPServer]?
        }
        let stderr = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // The stream starts with the system init event and ends with the result event.
        let events = output.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(Result.self, from: Data($0)) }
        let start = events.first { $0.type == "system" && $0.subtype == "init" }
        let result = events.last { $0.type == "result" }
        let setup = start.map { start in
            Setup(version: start.claude_code_version, permissionMode: start.permissionMode, model: start.model, tools: start.tools ?? [],
                  mcpServers: start.mcp_servers?.map(\.name) ?? [], thinkingTokens: result?.usage?.output_tokens_details?.thinking_tokens)
        }
        guard let result else {
            let text = exitStatus == 0 ? "Claude Code gave no answer." : "Claude Code stopped before answering, exit \(exitStatus)."
            return Answer(text: stderr.isEmpty ? text : "\(text)\n\(stderr)", seconds: seconds, costUSD: nil, failed: true, setup: setup)
        }
        let text = result.result ?? ""
        if text.contains("Failed to authenticate") || text.contains("Not logged in") {
            return Answer(text: "Log in to Claude Code: run claude in a terminal and type /login.", seconds: seconds, costUSD: nil, failed: true, setup: setup)
        }
        let failed = result.is_error == true || text.isEmpty || exitStatus != 0
        let shown = [text, result.errors?.joined(separator: "\n") ?? "", failed ? stderr : ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return Answer(text: shown.isEmpty ? "Claude gave no answer." : shown, seconds: seconds, costUSD: result.total_cost_usd, failed: failed,
                      sessionID: result.session_id, setup: setup)
    }
}

private extension Duration {
    var timeInSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
