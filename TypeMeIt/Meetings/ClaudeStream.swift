import Foundation
import Observation

/// Claude Code's `stream-json` output as a terminal would show it: the
/// session starting, each tool it calls and what came back, its words, and
/// the end.
enum ClaudeStream {
    /// What a tool's input or result shows of itself, so one call stays one line.
    static let summaryLength = 100

    enum Event: Equatable {
        case started(model: String, sessionID: String?)
        case lines([SquareClaudeLine])
        /// What came back, in order, for the calls still waiting.
        case results([String])
        case ended(seconds: Int?, failed: Bool)
    }

    /// What one line of the stream adds; nil for events with nothing to show.
    static func event(for line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = fields["type"] as? String else { return nil }
        let content = (fields["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        switch type {
        case "system" where fields["subtype"] as? String == "init":
            return .started(model: fields["model"] as? String ?? "claude", sessionID: fields["session_id"] as? String)
        case "assistant":
            let lines: [SquareClaudeLine] = content.compactMap { part in
                switch part["type"] as? String {
                // Claude Code loading its own tools, not work it does.
                case "tool_use" where part["name"] as? String == "ToolSearch": nil
                case "tool_use": .call("\(toolName(part["name"] as? String ?? "tool")) \(summary(part["input"]))", result: nil)
                case "text": (part["text"] as? String).map { .text($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                default: nil
                }
            }
            return lines.isEmpty ? nil : .lines(lines)
        case "user":
            let results = content.filter { part in
                part["type"] as? String == "tool_result"
                    && !((part["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "tool_reference" } ?? false)
            }
            return results.isEmpty ? nil : .results(results.map { summary($0["content"]) })
        case "result":
            return .ended(seconds: (fields["duration_ms"] as? Double).map { Int(($0 / 1000).rounded()) },
                          failed: fields["is_error"] as? Bool ?? false)
        default:
            return nil
        }
    }

    /// `mcp__typemeit__search_meetings` as `typemeit search_meetings`.
    static func toolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.dropFirst("mcp__".count).replacingOccurrences(of: "__", with: " ")
    }

    /// A tool's input or result as one short line: its text, or its values.
    private static func summary(_ value: Any?) -> String {
        let text: String = switch value {
        case let string as String: string
        case let parts as [[String: Any]]: parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        case let object as [String: Any]: object.keys.sorted().map { "\(object[$0]!)" }.joined(separator: " ")
        case let object?: "\(object)"
        default: ""
        }
        // typemeit's meeting tools open with a line telling Claude the meeting is data.
        let lines = text.split(whereSeparator: \.isNewline)
        let shown = lines.first.map { String($0) } == Meeting.dataReminder ? lines.dropFirst() : lines[...]
        let oneLine = shown.joined(separator: " ")
        return oneLine.count > summaryLength ? String(oneLine.prefix(summaryLength)) + "…" : oneLine
    }
}

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
            for result in results {
                guard let waiting = run.lines.firstIndex(where: { if case .call(_, nil) = $0 { true } else { false } }),
                      case .call(let call, _) = run.lines[waiting] else { break }
                run.lines[waiting] = .call(call, result: result)
            }
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
