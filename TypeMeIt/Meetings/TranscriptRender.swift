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
        if let name = meeting.names?.name {
            frontMatter.append("call: \(quoted(name))")
        }
        if let channel = meeting.names?.channel {
            frontMatter.append("channel: \(quoted(channel))")
            if let workspace = meeting.names?.workspace { frontMatter.append("workspace: \(quoted(workspace))") }
        } else if let code = meeting.names?.call {
            frontMatter.append("code: \(quoted(code))")
        }
        let speakers = meeting.speakers.map { quoted($0.name) }.joined(separator: ", ")
        frontMatter.append("speakers: [\(speakers)]")
        frontMatter.append("echo: \(meeting.echo.rawValue)")
        frontMatter.append("---")
        frontMatter.append("")
        var body = [paragraphs(meeting)]
        if let questions = meeting.questions, !questions.isEmpty { body.append("\n" + offered(questions)) }
        if let runs = meeting.hookRuns, !runs.isEmpty { body.append("\n" + hooks(runs)) }
        return (frontMatter + body).joined(separator: "\n") + "\n"
    }

    /// The questions offered to Claude Code: a heading per question with
    /// when it was heard, and the answer under it, or what the user did
    /// instead of asking. Headings, not the `**speaker** ·` form, so nothing
    /// reads it back as speech.
    static func offered(_ questions: [Meeting.Question]) -> String {
        (["## Questions for Claude"] + questions.map { question in
            let heading = "### \(question.text) · \(timestamp(ms: question.atMs))"
            guard question.result == .asked else { return "\(heading) · \(outcome(question.result))" }
            return question.answer.map { "\(heading)\n\n\($0)" } ?? heading
        })
        .joined(separator: "\n\n")
    }

    /// The hooks run on the meeting: a heading per run, its output under it.
    static func hooks(_ runs: [Meeting.HookRun]) -> String {
        (["## Hooks"] + runs.map { run in
            "### \(run.name)\(run.failed ? " · failed" : "")\n\n\(run.output)" + (run.sessionID.map { "\n\nclaude --resume \($0)" } ?? "")
        })
            .joined(separator: "\n\n")
    }

    /// A turn of the meeting's page, or a question offered to Claude, by index.
    enum Entry: Hashable {
        case paragraph(Int)
        case question(Int)
    }

    /// The turns in order, each question after the last turn that started
    /// before it was heard.
    static func entries(_ meeting: Meeting) -> [Entry] {
        let questions = Array((meeting.questions ?? []).enumerated()).sorted { $0.element.atMs < $1.element.atMs }
        var next = 0
        var entries: [Entry] = []
        for (i, paragraph) in meeting.paragraphs.enumerated() {
            while next < questions.count, questions[next].element.atMs < paragraph.startMs {
                entries.append(.question(questions[next].offset))
                next += 1
            }
            entries.append(.paragraph(i))
        }
        return entries + questions[next...].map { .question($0.offset) }
    }

    /// What became of a question, as the transcript and the meeting's page say it.
    static func outcome(_ outcome: Meeting.Question.Outcome) -> String {
        switch outcome {
        case .asked: "asked"
        case .dismissed: "dismissed"
        case .ignored: "not asked"
        case .cancelled: "cancelled"
        }
    }

    /// One `**speaker** · timestamp` / text block per paragraph, blank-line
    /// separated.
    static func paragraphs(_ meeting: Meeting) -> String {
        meeting.paragraphs
            .map { "**\(meeting.speakerName($0.speaker))** · \(timestamp(ms: $0.startMs))\n\($0.text)" }
            .joined(separator: "\n\n")
    }
}
