import SwiftUI

/// A Claude Code run as `SquareClaudeThread` shows it: streamed live while
/// this session runs it, otherwise from what was kept.
struct ClaudeRunOutput: View {
    /// What was kept of a finished run.
    struct Kept {
        let prompt: String
        let answer: String
        let failed: Bool
        var sessionID: String?
        var calls: [Meeting.ToolCall]?
    }

    let id: UUID
    var kept: Kept?
    @State private var live = ClaudeLive.shared

    var body: some View {
        if let run = live.runs[id] {
            let running = live.running.contains(id)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = run.seconds ?? Int(context.date.timeIntervalSince(run.started))
                let failed = run.failed || (!running && kept?.failed == true)
                SquareClaudeThread(lines: [.prompt(run.prompt)] + run.lines + (failed && !run.lines.contains(where: Self.isText) ? kept.map { [.error($0.answer)] } ?? [] : []),
                                   status: running ? .running : failed ? .failed : .done,
                                   footer: ([running || !failed ? nil : "failed", "\(seconds) s", run.model].compactMap { $0 }).joined(separator: " · "),
                                   sessionID: run.sessionID,
                                   stop: { live.cancel(id) })
            }
        } else if let kept {
            SquareClaudeThread(lines: [.prompt(kept.prompt)] + (kept.calls ?? []).map { .call($0.name, result: $0.result) }
                                   + [kept.failed ? .error(kept.answer) : .text(kept.answer)],
                               status: kept.failed ? .failed : .done,
                               footer: kept.failed ? "failed" : "",
                               sessionID: kept.sessionID)
        }
    }

    private static func isText(_ line: SquareClaudeLine) -> Bool {
        if case .text = line { true } else { false }
    }
}
