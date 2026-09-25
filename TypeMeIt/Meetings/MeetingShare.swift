import Foundation

/// A meeting as a `.tmi` file (docs/meetings.md 7.16): `transcript.md`'s
/// Markdown with who shared it, the meeting's id and the format's version
/// added to the front matter. A text editor shows it as a transcript; type
/// me it opens it as a meeting without audio. Pure: `MeetingStore` reads
/// and writes the files.
enum MeetingShare {
    /// As declared for `it.typeme.meeting` in project.yml.
    static let fileExtension = "tmi"
    /// The format this build writes, and the newest it reads.
    static let version = 1
    /// On its own line under the front matter, for anyone who opens the file
    /// without type me it. Reading skips everything before the first heading.
    static let website = Fixed.websiteURL.host() ?? Fixed.websiteURL.absoluteString

    enum ReadError: Error, Equatable {
        /// No front matter, or no id or start time in it.
        case notAMeeting
        /// Written by a later build, in a format this one does not know.
        case newerVersion
    }

    // MARK: Writing

    /// The file's text. The user's own speaker is named `sender` unless the
    /// user renamed it: in anyone else's copy, "You" is the wrong person.
    static func markdown(_ meeting: Meeting, sender: String) -> String {
        var shared = meeting
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
            "format: \(version)",
            "---",
            "",
        ]
        return (frontMatter + [website, "", TranscriptRender.paragraphs(shared)]).joined(separator: "\n") + "\n"
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
        var turns: [(name: String, startMs: Int, lines: [Substring])] = []
        for line in lines[(close + 1)...] {
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
            sharedBy: string(fields["from"]) ?? "")
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
