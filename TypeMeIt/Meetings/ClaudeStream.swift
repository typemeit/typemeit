import Foundation

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

    /// `lines` with each result put in the earliest call still waiting for
    /// one; a result with no call waiting is dropped.
    static func filling(_ lines: [SquareClaudeLine], with results: [String]) -> [SquareClaudeLine] {
        var filled = lines
        for result in results {
            guard let waiting = filled.firstIndex(where: { if case .call(_, nil) = $0 { true } else { false } }),
                  case .call(let call, _) = filled[waiting] else { break }
            filled[waiting] = .call(call, result: result)
        }
        return filled
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
        let shown = lines.first.map { String($0) } == MeetingDataReminder.line ? lines.dropFirst() : lines[...]
        let oneLine = shown.joined(separator: " ")
        return oneLine.count > summaryLength ? String(oneLine.prefix(summaryLength)) + "…" : oneLine
    }
}
