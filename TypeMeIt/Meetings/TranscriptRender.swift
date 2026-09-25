import Foundation

/// Renders a `Meeting` as the Markdown transcript beside it (docs/meetings.md
/// 7.9). Pure: the file is written by `MeetingStore`, never read back.
enum TranscriptRender {
    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The `started` line's format; `MeetingShare` reads it back.
    static let startedFormat = "yyyy-MM-dd HH:mm xxx"

    static func startedLine(_ meeting: Meeting) -> String {
        let zone = TimeZone(identifier: meeting.timeZone) ?? TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = startedFormat
        return formatter.string(from: meeting.started)
    }

    /// `m:ss` from the start, or `h:mm:ss` past an hour.
    static func timestamp(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        guard hours > 0 else { return String(format: "%d:%02d", minutes, seconds) }
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    /// The front matter plus one `**speaker** · timestamp` / text block per
    /// paragraph, blank-line separated, ending in one newline.
    static func markdown(_ meeting: Meeting) -> String {
        var frontMatter = [
            "---",
            "title: \(quoted(meeting.title))",
            "kind: \(meeting.kind.rawValue)",
            "started: \(quoted(startedLine(meeting)))",
            "duration: \(timestamp(ms: meeting.durationMs))",
        ]
        if let app = meeting.app {
            frontMatter.append("app: \(quoted(app.name))")
        }
        let speakers = meeting.speakers.map { quoted($0.name) }.joined(separator: ", ")
        frontMatter.append("speakers: [\(speakers)]")
        frontMatter.append("echo: \(meeting.echo.rawValue)")
        frontMatter.append("---")
        frontMatter.append("")
        return (frontMatter + [paragraphs(meeting)]).joined(separator: "\n") + "\n"
    }

    /// One `**speaker** · timestamp` / text block per paragraph, blank-line
    /// separated.
    static func paragraphs(_ meeting: Meeting) -> String {
        meeting.paragraphs
            .map { "**\(meeting.speakerName($0.speaker))** · \(timestamp(ms: $0.startMs))\n\($0.text)" }
            .joined(separator: "\n\n")
    }
}
