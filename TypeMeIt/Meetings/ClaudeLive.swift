import Foundation
import Observation

/// What each Claude Code run is printing, by an id its page knows (the
/// dictation that asked, the hook run), and how to stop it. Kept until the
/// app quits; `ClaudeRunOutput` shows it.
@MainActor
@Observable
final class ClaudeLive {
    static let shared = ClaudeLive()

    struct Run {
        let prompt: String
        let started = Date()
        var lines: [SquareClaudeLine] = []
        var model: String?
        var sessionID: String?
        var seconds: Int?
        var failed = false
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
        guard var run = runs[id] else { return }
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
        runs[id] = run
    }

    func finish(_ id: UUID) {
        running.remove(id)
        cancels[id] = nil
    }

    func cancel(_ id: UUID) {
        cancels[id]?()
    }
}
