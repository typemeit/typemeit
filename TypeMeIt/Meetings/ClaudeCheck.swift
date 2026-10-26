import Foundation
import Observation

/// Runs Claude Code the two ways the app does and holds what each run says it
/// ran with against what it was asked for. Claude Code updates itself, and a
/// newer one can take a flag and ignore it; ask and hooks then go wrong with
/// no error. Checked: the permission mode, the removed Agent tool, the
/// appended system prompt reaching Claude, and the question run's bare,
/// thinking-off Haiku.
@MainActor
@Observable
final class ClaudeCheck {
    static let shared = ClaudeCheck()

    /// What a pass holds for: the installed Claude Code, by the file its
    /// command resolves to (each version is its own file), and the settings
    /// ask and hooks run with.
    struct Conditions: Codable, Equatable {
        var claude: String
        var folder: String
        var model: String
        var permissionMode: String
        var tools: [String]
    }

    enum Status: Equatable {
        case unchecked, checking
        case installing(version: String)
        case passed(version: String?)
        /// `error` is a run's own, when one failed outright; `problems` are where they ran other than asked.
        case failed(version: String?, problems: [String], error: String?)
    }

    struct Run {
        let id: UUID
        let prompt: String
        var answer: ClaudeRun.Answer?
    }

    private struct Pass: Codable {
        let conditions: Conditions
        let version: String?
    }

    private struct Failure {
        let conditions: Conditions?
        let version: String?
        var problems: [String] = []
        var error: String?
    }

    /// The last check's two runs, for settings to show.
    private(set) var runs: [Run] = []
    /// A check failed that the user did not start, so they are not looking at it.
    @ObservationIgnored var onUnaskedFailure: (@MainActor () -> Void)?

    private static let passKey = "claudeCheckPassed"
    private static let hourly: Duration = .seconds(3600)
    /// `claude install` downloads the version first.
    private static let installTimeoutSeconds = 300.0
    private static let questionPrompt = "find the latest question"
    /// What the question run reads; any transcript with a question will do.
    private static let sampleTranscript = """
        **Alex** 00:05 So we moved the launch to the twelfth.

        **Sam** 00:20 Right. And are we keeping the free tier on the pricing page?
        """

    private var pass: Pass? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(pass), forKey: Self.passKey) }
    }
    private var failure: Failure?
    private var checking: Conditions?
    private var installing: String?
    @ObservationIgnored private var waiting: [@MainActor (Bool) -> Void] = []
    @ObservationIgnored private var watching = false

    private init() {
        pass = UserDefaults.standard.data(forKey: Self.passKey).flatMap { try? JSONDecoder().decode(Pass.self, from: $0) }
    }

    /// Nil when Claude Code is not installed or this build cannot run it.
    static var conditions: Conditions? {
        guard ClaudeRun.isAvailable, let claude = ClaudeRun.executable else { return nil }
        let settings = Settings.shared
        return Conditions(claude: claude.resolvingSymlinksInPath().path, folder: settings.askClaudeFolder, model: settings.askClaudeModel,
                          permissionMode: settings.askClaudePermissionMode, tools: settings.askClaudeTools)
    }

    /// Ask or a hook is on, so Claude Code has to keep working.
    static var inUse: Bool { Settings.shared.askClaude || Settings.shared.meetingHooks.contains(where: \.on) }

    var status: Status {
        let now = Self.conditions
        if let installing { return .installing(version: installing) }
        if checking != nil { return .checking }
        if let pass, pass.conditions == now { return .passed(version: pass.version) }
        if let failure, failure.conditions == now { return .failed(version: failure.version, problems: failure.problems, error: failure.error) }
        return .unchecked
    }

    var lastPassed: String? { pass?.version }

    /// The version that last passed, when a newer one fails because it runs
    /// differently: going back to it is the fix.
    var rollback: String? {
        guard Self.installedNatively, case .failed(let version, let problems, nil) = status, !problems.isEmpty,
              let passed = pass?.version, passed != version else { return nil }
        return passed
    }

    /// The check row's caption: the version and whether it works, or a run's own error.
    nonisolated static func caption(_ status: Status, lastPassed: String?) -> String? {
        switch status {
        case .unchecked: return nil
        case .checking: return "checking"
        case .installing(let version): return "installing \(version)"
        case .passed(let version): return [version, "working"].compactMap { $0 }.joined(separator: " · ")
        case .failed(_, _, let error?):
            let line = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
            return line.hasSuffix(".") ? String(line.dropLast()) : line
        case .failed(let version, _, nil):
            let reason = lastPassed != nil && lastPassed == version ? "doesn't work with these settings" : "not supported yet"
            return [version, reason].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Installed by Claude Code's own installer, which keeps each version
    /// under this folder and can go back to one with `claude install`.
    static var installedNatively: Bool {
        ClaudeRun.executable?.resolvingSymlinksInPath().path.contains("/.local/share/claude/versions/") ?? false
    }

    /// Checks unless these conditions already passed; `done` hears whether they pass.
    func ensure(_ done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        if case .passed = status { done(true) } else { run(done) }
    }

    /// Checks now, whatever passed before.
    func run(_ done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        waiting.append(done)
        guard let conditions = Self.conditions else {
            finish(Failure(conditions: nil, version: nil, error: "claude code isn't installed"))
            return
        }
        guard checking != conditions else { return }
        checking = conditions
        Task {
            let failure = await check(conditions)
            // Settings changed while it ran; the check for the new ones answers.
            guard checking == conditions else { return }
            checking = nil
            finish(failure)
        }
    }

    /// Checks in the background when ask or a hook is on and these
    /// conditions have neither passed nor already failed, telling the user
    /// through `onUnaskedFailure`.
    func recheckIfStale() {
        guard Self.inUse, checking == nil, Self.conditions != nil, status == .unchecked else { return }
        run { [weak self] passed in if !passed { self?.onUnaskedFailure?() } }
    }

    /// Installs `version` with Claude Code's own installer, then checks it.
    func rollBack(to version: String) {
        guard installing == nil, let claude = ClaudeRun.executable else { return }
        installing = version
        Task {
            let error = await Self.install(version, with: claude)
            installing = nil
            if let error {
                DebugLog.write("Claude check: installing \(version) failed: \(error)")
                failure = Failure(conditions: Self.conditions, version: failure?.version, error: "couldn't install \(version): \(error)")
            } else {
                run()
            }
        }
    }

    /// Nil once installed, else what the installer printed.
    nonisolated private static func install(_ version: String, with claude: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = claude
                process.arguments = ["install", version]
                process.environment = ClaudeRun.environment
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                guard (try? process.run()) != nil else { return continuation.resume(returning: "claude did not start") }
                DispatchQueue.global().asyncAfter(deadline: .now() + installTimeoutSeconds) { if process.isRunning { process.terminate() } }
                let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                let trimmed = printed.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: process.terminationStatus == 0 ? nil : trimmed.isEmpty ? "exit \(process.terminationStatus)" : trimmed)
            }
        }
    }

    /// Rechecks now and every hour, which notices Claude Code updating itself.
    func watch() {
        guard !watching else { return }
        watching = true
        recheckIfStale()
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.hourly)
                self?.recheckIfStale()
            }
        }
    }

    private func finish(_ failure: Failure?) {
        self.failure = failure
        let callbacks = waiting
        waiting = []
        for done in callbacks { done(failure == nil) }
    }

    private func check(_ conditions: Conditions) async -> Failure? {
        let code = UUID().uuidString
        guard let main = ClaudeRun.test(code: code, folder: URL(fileURLWithPath: conditions.folder, isDirectory: true), model: conditions.model,
                                        allowedTools: conditions.tools, permissionMode: conditions.permissionMode,
                                        userSystemPrompt: Settings.shared.askClaudeSystemPrompt),
              let question = ClaudeRun.latestQuestion(in: Self.sampleTranscript) else {
            return Failure(conditions: conditions, version: nil, error: "claude code isn't installed")
        }
        runs = [Run(id: UUID(), prompt: ClaudeRun.testPrompt), Run(id: UUID(), prompt: Self.questionPrompt)]
        let (mainID, questionID) = (runs[0].id, runs[1].id)
        ClaudeLive.shared.start(mainID, prompt: ClaudeRun.testPrompt, run: main) { main.cancel() }
        ClaudeLive.shared.start(questionID, prompt: Self.questionPrompt, run: question) { question.cancel() }
        async let mainAnswer = main.answer()
        async let questionAnswer = question.answer()
        let answers = await (main: mainAnswer, question: questionAnswer)
        ClaudeLive.shared.finish(mainID)
        ClaudeLive.shared.finish(questionID)
        runs[0].answer = answers.main
        runs[1].answer = answers.question
        let version = answers.main.setup?.version ?? answers.question.setup?.version
        let problems = Self.problems(main: answers.main, code: code, permissionMode: conditions.permissionMode, question: answers.question)
        if problems.isEmpty, !answers.main.failed, !answers.question.failed {
            pass = Pass(conditions: conditions, version: version)
            return nil
        }
        let error = [answers.main, answers.question].first(where: \.failed)?.text
        DebugLog.write("Claude check failed on \(version ?? "unknown version"): \(([error].compactMap { $0 } + problems).joined(separator: " · "))")
        return Failure(conditions: conditions, version: version, problems: problems, error: error)
    }

    /// Where the two runs did not run as asked: the ask and hook run given
    /// `code` in its system prompt and `permissionMode`, and the question run.
    /// A run that failed outright shows its own error and adds nothing here.
    nonisolated static func problems(main: ClaudeRun.Answer, code: String, permissionMode: String, question: ClaudeRun.Answer) -> [String] {
        var problems: [String] = []
        if !main.failed {
            if let setup = main.setup {
                if setup.permissionMode != permissionMode {
                    problems.append("ran in \(setup.permissionMode ?? "no") permission mode, not \(permissionMode)")
                }
                if setup.tools.contains(ClaudeRun.disallowedTool) { problems.append("\(ClaudeRun.disallowedTool) tool not removed") }
                if !main.text.contains(code) { problems.append("system prompt not applied") }
            } else {
                problems.append("no start event")
            }
        }
        if !question.failed {
            if let setup = question.setup {
                if !setup.tools.isEmpty { problems.append("finding the question: has \(counted(setup.tools.count, "tool"))") }
                if !setup.mcpServers.isEmpty { problems.append("finding the question: started \(counted(setup.mcpServers.count, "mcp server"))") }
                if !(setup.model ?? "").contains(ClaudeRun.questionModel) { problems.append("finding the question: ran on \(setup.model ?? "no model"), not \(ClaudeRun.questionModel)") }
                switch setup.thinkingTokens {
                case nil: problems.append("finding the question: thinking not reported")
                case let tokens? where tokens > 0: problems.append("finding the question: thinking is back on")
                default: break
                }
            } else {
                problems.append("finding the question: no start event")
            }
        }
        return problems
    }
}
