import Foundation

/// A meeting as a `.tmi` file (docs/meetings.md 7.16): `transcript.md`'s
/// Markdown with who shared it, the meeting's id and the format's version
/// added to the front matter, and Claude's answers and hook results when
/// the user chose to include them. A text editor shows it as a transcript;
/// type me it opens it as a meeting without audio. Pure: `MeetingStore`
/// reads and writes the files.
enum MeetingShare {
    /// As declared for `it.typeme.meeting` in project.yml.
    static let fileExtension = "tmi"
    /// The newest format this build reads. A file with no Claude answers or
    /// hook results is written as format 1, which builds from before
    /// `claudeFormat` open; one with them is `claudeFormat`, which those
    /// builds refuse rather than read the answers as the last speaker's words.
    static let version = claudeFormat
    static let transcriptFormat = 1
    static let claudeFormat = 2
    /// On its own line under the front matter, for anyone who opens the file
    /// without type me it. Reading skips everything before the first heading.
    static let website = Fixed.websiteURL.host() ?? Fixed.websiteURL.absoluteString

    enum ReadError: Error, Equatable {
        /// No front matter, or no id or start time in it.
        case notAMeeting
        /// Written by a later build, in a format this one does not know.
        case newerVersion
    }

    // MARK: Claude's part

    /// The questions Claude answered: offered ones the user turned down or
    /// let pass are not the meeting's to share.
    static func answers(_ meeting: Meeting) -> [Meeting.Question] {
        (meeting.questions ?? []).filter { $0.result == .asked && $0.answer?.isEmpty == false }
    }

    /// The hook runs that came back with a result.
    static func hookResults(_ meeting: Meeting) -> [Meeting.HookRun] {
        (meeting.hookRuns ?? []).filter { !$0.failed }
    }

    static func hasClaude(_ meeting: Meeting) -> Bool { !answers(meeting).isEmpty || !hookResults(meeting).isEmpty }

    /// Opens a question or hook run: an HTML comment, which Markdown viewers
    /// hide, holding what the heading under it can't carry back exactly.
    /// Answers and hook results are Markdown with headings of their own, so
    /// only this line can say where one ends.
    private static let markPrefix = "<!-- tmi "
    private static let markSuffix = " -->"
    private enum MarkKind: String { case ask, hook }

    private struct AskMark: Codable {
        var atMs: Int
        var text: String
    }

    private struct HookMark: Codable {
        var id: UUID
        var name: String
        var prompt: String
        var ranAt: Date
    }

    private static func mark<Mark: Encodable>(_ kind: MarkKind, _ mark: Mark) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(mark) else { return markPrefix + kind.rawValue + markSuffix }
        // `>` only ever appears inside a JSON string here, so escaping it
        // keeps a "-->" in a question from closing the comment early.
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: ">", with: "\\u003e")
        return markPrefix + kind.rawValue + " " + json + markSuffix
    }

    /// The answers, then the hook results, under the headings `transcript.md` uses.
    private static func claudeSections(_ meeting: Meeting) -> [String] {
        var sections: [String] = []
        let answers = answers(meeting)
        if !answers.isEmpty {
            sections.append(([TranscriptRender.questionsHeading] + answers.map { question in
                [mark(.ask, AskMark(atMs: question.atMs, text: question.text)), TranscriptRender.questionHeading(question), "", question.answer ?? ""]
                    .joined(separator: "\n")
            }).joined(separator: "\n\n"))
        }
        let runs = hookResults(meeting)
        if !runs.isEmpty {
            sections.append(([TranscriptRender.hooksHeading] + runs.map { run in
                [mark(.hook, HookMark(id: run.id, name: run.name, prompt: run.prompt, ranAt: run.ranAt)), TranscriptRender.hookHeading(run), "", run.output]
                    .joined(separator: "\n")
            }).joined(separator: "\n\n"))
        }
        return sections
    }

    // MARK: Writing

    /// The file's text. The user's own speaker is named `sender` unless the
    /// user renamed it: in anyone else's copy, "You" is the wrong person.
    /// `includingClaude` adds Claude's answers and hook results, which only
    /// go when the user says so: they can hold what Claude read elsewhere.
    static func markdown(_ meeting: Meeting, sender: String, includingClaude: Bool = false) -> String {
        var shared = meeting.withoutBackground
        for i in shared.speakers.indices where shared.speakers[i].isYou && shared.speakers[i].nameSource != .user {
            shared.speakers[i].name = sender
        }
        var frontMatter = [
            "---",
            "title: \(quoted(shared.title))",
            "kind: \(shared.kind.rawValue)",
            "started: \(quoted(TranscriptRender.startedLine(shared)))",
            "duration: \(TranscriptRender.timestamp(ms: shared.durationMs))",
        ]
        if let app = shared.app {
            frontMatter.append("app: \(quoted(app.name))")
        }
        frontMatter += [
            "speakers: [\(shared.speakers.map { quoted($0.name) }.joined(separator: ", "))]",
            "from: \(quoted(sender))",
            "id: \(shared.id.uuidString)",
        ]
        let claude = includingClaude ? claudeSections(shared) : []
        frontMatter += ["format: \(claude.isEmpty ? transcriptFormat : claudeFormat)", "---", ""]
        return (frontMatter + [website, "", ([TranscriptRender.paragraphs(shared)] + claude).joined(separator: "\n\n")]).joined(separator: "\n") + "\n"
    }

    /// JSON's string syntax, which YAML reads as a double-quoted string:
    /// quotes, backslashes and line breaks are escaped, so a value stays on
    /// its line and reads back exactly.
    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Reading

    /// The meeting a `.tmi` file describes: transcribed, published, without
    /// audio, and shared by whoever `from` names. The file has start times
    /// only, so a paragraph ends where the next begins, and the last at the
    /// meeting's end. Speakers are numbered in the order the file lists them.
    static func meeting(from text: String) throws -> Meeting {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.first, isFence(first),
              let close = lines.indices.dropFirst().first(where: { isFence(lines[$0]) }) else { throw ReadError.notAMeeting }
        var fields: [String: String] = [:]
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if let written = fields["format"].flatMap({ Int($0) }), written > version { throw ReadError.newerVersion }
        guard let id = fields["id"].flatMap({ UUID(uuidString: $0) }),
              let start = string(fields["started"]).flatMap(startedTime) else { throw ReadError.notAMeeting }
        let durationMs = fields["duration"].flatMap { milliseconds($0[...]) } ?? 0

        var names = list(fields["speakers"])
        let body = lines[(close + 1)...]
        let claudeStart = body.firstIndex { isClaudeLine($0) } ?? body.endIndex
        var turns: [(name: String, startMs: Int, lines: [Substring])] = []
        for line in body[..<claudeStart] {
            // A line that only looks like a heading, naming no listed speaker, is words.
            if let heading = heading(line), names.isEmpty || names.contains(heading.name) {
                turns.append((heading.name, heading.startMs, []))
            } else if !turns.isEmpty {
                turns[turns.count - 1].lines.append(line)
            }
        }
        for turn in turns where !names.contains(turn.name) { names.append(turn.name) }
        let ids = Dictionary(names.enumerated().map { ($1, speakerId($0)) }, uniquingKeysWith: { first, _ in first })

        let paragraphs = turns.indices.map { i in
            let turn = turns[i]
            let end = turns.indices.contains(i + 1) ? turns[i + 1].startMs : durationMs
            return Meeting.Paragraph(speaker: ids[turn.name] ?? turn.name, startMs: turn.startMs, endMs: max(end, turn.startMs),
                                     text: turn.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let speakers = names.indices.map { i in
            let said = paragraphs.filter { $0.speaker == speakerId(i) }
            return Meeting.Speaker(id: speakerId(i), name: names[i], isYou: false,
                                   talkMs: said.map { $0.endMs - $0.startMs }.reduce(0, +), nameSource: .user)
        }
        let title = string(fields["title"]) ?? ""
        let claude = claudeParts(body[claudeStart...])

        return Meeting(
            id: id,
            kind: string(fields["kind"]).flatMap(Meeting.Kind.init(rawValue:)) ?? .call,
            started: start.date,
            timeZone: start.zone.identifier,
            ended: start.date.addingTimeInterval(TimeInterval(durationMs) / 1000),
            durationMs: durationMs,
            recordedMs: durationMs,
            firstHostTime: nil,
            // The file names the app, not its bundle id.
            app: string(fields["app"]).map { Meeting.App(bundleId: "", name: $0) },
            title: title.isEmpty ? "meeting" : title,
            titleSource: .user,
            published: true,
            tracks: [],
            audio: nil,
            echo: .notMeasured,
            bothSilentMs: 0,
            dictations: [],
            speakers: speakers,
            transcription: Meeting.Transcription(state: .done, error: nil, asr: nil, diarizer: nil, tookMs: nil),
            paragraphs: paragraphs,
            sharedBy: string(fields["from"]) ?? "",
            questions: claude.questions.isEmpty ? nil : claude.questions,
            hookRuns: claude.hookRuns.isEmpty ? nil : claude.hookRuns)
    }

    /// Where the transcript ends: a mark, or a heading Claude's part starts with.
    private static func isClaudeLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(markPrefix) || trimmed == TranscriptRender.questionsHeading || trimmed == TranscriptRender.hooksHeading
    }

    /// The questions and hook runs after the transcript, one per mark. Each
    /// mark's text runs to the next mark, less the heading under the mark
    /// and the section heading that may close it.
    private static func claudeParts(_ lines: ArraySlice<Substring>) -> (questions: [Meeting.Question], hookRuns: [Meeting.HookRun]) {
        var items: [(kind: MarkKind, json: Data, lines: [Substring])] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(markPrefix), trimmed.hasSuffix(markSuffix) {
                let inside = trimmed.dropFirst(markPrefix.count).dropLast(markSuffix.count)
                let kind = inside.prefix { $0 != " " }
                guard let markKind = MarkKind(rawValue: String(kind)) else { continue }
                items.append((markKind, Data(inside.dropFirst(kind.count).utf8), []))
            } else if !items.isEmpty {
                items[items.count - 1].lines.append(line)
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var questions: [Meeting.Question] = []
        var runs: [Meeting.HookRun] = []
        for item in items {
            var text = Array(item.lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.dropFirst())
            while let last = text.last, last.trimmingCharacters(in: .whitespaces).isEmpty || isClaudeLine(last) { text.removeLast() }
            let joined = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            switch item.kind {
            case .ask:
                guard let mark = try? decoder.decode(AskMark.self, from: item.json) else { continue }
                questions.append(Meeting.Question(atMs: mark.atMs, text: mark.text, answer: joined, outcome: .asked))
            case .hook:
                guard let mark = try? decoder.decode(HookMark.self, from: item.json) else { continue }
                runs.append(Meeting.HookRun(id: mark.id, name: mark.name, prompt: mark.prompt, ranAt: mark.ranAt, output: joined, failed: false))
            }
        }
        return (questions, runs)
    }

    /// `s1`, `s2`, …, as a room's speakers are numbered.
    private static func speakerId(_ index: Int) -> String { "s\(index + 1)" }

    private static func isFence(_ line: Substring) -> Bool { line.trimmingCharacters(in: .whitespaces) == "---" }

    /// A front matter value: a string as `quoted` writes it, or bare text.
    private static func string(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard raw.hasPrefix("\"") else { return raw }
        return try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
    }

    /// A front matter list of strings, `["a", "b"]`.
    private static func list(_ raw: String?) -> [String] {
        guard let raw, raw.hasPrefix("[") else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }

    /// The `started` line's time, and its offset as the meeting's zone: the
    /// only zone the line carries.
    static func startedTime(_ text: String) -> (date: Date, zone: TimeZone)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = TranscriptRender.startedFormat
        guard let date = formatter.date(from: text), let offset = text.split(separator: " ").last,
              let sign = offset.first, sign == "+" || sign == "-" else { return nil }
        let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2,
              let zone = TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (parts[0] * 3600 + parts[1] * 60)) else { return nil }
        return (date, zone)
    }

    /// The speaker and start of a `**Name** · 1:23` heading line.
    static func heading(_ line: Substring) -> (name: String, startMs: Int)? {
        guard line.hasPrefix("**"), let close = line.range(of: "** · ", options: .backwards) else { return nil }
        let nameStart = line.index(line.startIndex, offsetBy: 2)
        guard close.lowerBound > nameStart, let ms = milliseconds(line[close.upperBound...]) else { return nil }
        return (String(line[nameStart..<close.lowerBound]), ms)
    }

    /// `m:ss` or `h:mm:ss`, as `TranscriptRender.timestamp` writes them.
    static func milliseconds(_ text: Substring) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var seconds = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            seconds = seconds * 60 + n
        }
        return seconds * 1000
    }
}
