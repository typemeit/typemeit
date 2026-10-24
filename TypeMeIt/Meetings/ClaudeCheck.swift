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
        case passed(version: String?)
        case failed(version: String?, problems: [String])
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
        let problems: [String]
    }

    /// The last check's two runs, for settings to show.
    private(set) var runs: [Run] = []
    /// A check failed that the user did not start, so they are not looking at it.
    @ObservationIgnored var onUnaskedFailure: (@MainActor () -> Void)?

    private static let passKey = "claudeCheckPassed"
    private static let hourly: Duration = .seconds(3600)
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
        if checking != nil { return .checking }
        if let pass, pass.conditions == now { return .passed(version: pass.version) }
        if let failure, failure.conditions == now { return .failed(version: failure.version, problems: failure.problems) }
        return .unchecked
    }

    /// Checks unless these conditions already passed; `done` hears whether they pass.
    func ensure(_ done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        if case .passed = status { done(true) } else { run(done) }
    }

    /// Checks now, whatever passed before.
    func run(_ done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        waiting.append(done)
        guard let conditions = Self.conditions else {
            finish(Failure(conditions: nil, version: nil, problems: ["claude code isn't installed"]))
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
            return Failure(conditions: conditions, version: nil, problems: ["claude code isn't installed"])
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
        let errors = [answers.main, answers.question].filter(\.failed).map(\.text)
        DebugLog.write("Claude check failed on \(version ?? "unknown version"): \((errors + problems).joined(separator: " · "))")
        return Failure(conditions: conditions, version: version, problems: problems)
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
                if !setup.tools.isEmpty { problems.append("question run has \(counted(setup.tools.count, "tool"))") }
                if !setup.mcpServers.isEmpty { problems.append("question run started \(counted(setup.mcpServers.count, "mcp server"))") }
                if !(setup.model ?? "").contains(ClaudeRun.questionModel) { problems.append("question run on \(setup.model ?? "no model"), not \(ClaudeRun.questionModel)") }
                switch setup.thinkingTokens {
                case nil: problems.append("question run's thinking not reported")
                case let tokens? where tokens > 0: problems.append("question run thought for \(counted(tokens, "token"))")
                default: break
                }
            } else {
                problems.append("question run: no start event")
            }
        }
        return problems
    }
}
