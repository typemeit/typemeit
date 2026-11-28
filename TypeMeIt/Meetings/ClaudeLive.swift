import Foundation
import Observation

/// What each Claude Code run is printing, by an id its page knows (the
/// dictation that asked, the hook run), and how to stop it. Kept until the
/// app quits; `ClaudeRunOutput` shows it.
@MainActor
@Observable
final class ClaudeLive {
    static let shared = ClaudeLive()

    /// Its own observable, so a line streamed into one run redraws only
    /// the views showing that run; `runs` changes only when a run starts.
    @MainActor
    @Observable
    final class Run {
        let prompt: String
        let started = Date()
        var lines: [SquareClaudeLine] = []
        var model: String?
        var sessionID: String?
        var seconds: Int?
        var failed = false

        init(prompt: String) { self.prompt = prompt }
    }

    private(set) var runs: [UUID: Run] = [:]
    private(set) var running: Set<UUID> = []
    @ObservationIgnored private var cancels: [UUID: @MainActor () -> Void] = [:]

    /// Streams `run`'s output under `id` until `finish`; `cancel` is what
    /// stop does while it runs.
    func start(_ id: UUID, prompt: String, run: ClaudeRun, cancel: @escaping @MainActor () -> Void) {
        runs[id] = Run(prompt: prompt)
        running.insert(id)
        cancels[id] = cancel
        run.onLine = { line in
            guard let event = ClaudeStream.event(for: line) else { return }
            Task { @MainActor in ClaudeLive.shared.apply(event, to: id) }
        }
    }

    func apply(_ event: ClaudeStream.Event, to id: UUID) {
        guard let run = runs[id] else { return }
        switch event {
        case .started(let model, let sessionID):
            run.model = model
            run.sessionID = sessionID
        case .lines(let lines):
            run.lines += lines
        case .results(let results):
            run.lines = ClaudeStream.filling(run.lines, with: results)
        case .ended(let seconds, let failed):
            run.seconds = seconds
            run.failed = failed
        }
    }

    /// The tools `id`'s run called, to keep with its answer; nil for none.
    func calls(_ id: UUID) -> [Meeting.ToolCall]? {
        let calls = runs[id]?.lines.compactMap { line -> Meeting.ToolCall? in
            if case .call(let name, let result) = line { Meeting.ToolCall(name: name, result: result) } else { nil }
        } ?? []
        return calls.isEmpty ? nil : calls
    }

    /// A run that exited without its result line keeps how long it ran.
    func finish(_ id: UUID) {
        if let run = runs[id], run.seconds == nil { run.seconds = Int(Date().timeIntervalSince(run.started)) }
        running.remove(id)
        cancels[id] = nil
    }

    func cancel(_ id: UUID) {
        cancels[id]?()
    }
}
