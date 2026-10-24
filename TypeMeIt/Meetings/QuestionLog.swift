import Foundation

/// Every question the live transcript spotted and what came of it, one JSON
/// line per step in `question-log.jsonl`: the check's verdict, then the
/// user's answer in the pill. The answers are what the check learns from.
enum QuestionLog {
    enum Answer: String, Codable, Sendable {
        /// Asked Claude.
        case ask
        /// Said it was not a question to ask.
        case no
        /// Let the pill go without answering.
        case ignored
    }

    struct Entry: Codable, Equatable, Sendable {
        enum Step: String, Codable, Sendable { case checked, answered }
        let id: UUID
        let at: Date
        let step: Step
        let question: String
        var meeting: UUID? = nil
        var verdict: QuestionCheck.Verdict? = nil
        var checkSeconds: Double? = nil
        var answer: Answer? = nil
    }

    nonisolated static let url = SupportPaths.directory.appendingPathComponent("question-log.jsonl")

    static func append(_ entry: Entry) {
        guard var line = try? StoredJSON.lineEncoder.encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    static func read() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? StoredJSON.decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    /// The user's own yes and no answers, newest first and at most `limit` of
    /// each, for the check's prompt. Letting a pill go says nothing either way.
    static func examples(in entries: [Entry], limit: Int) -> (wanted: [String], unwanted: [String]) {
        let answered = entries.filter { $0.step == .answered }.sorted { $0.at > $1.at }
        let wanted = answered.filter { $0.answer == .ask }.map(\.question)
        let unwanted = answered.filter { $0.answer == .no }.map(\.question)
        return (Array(unique(wanted).prefix(limit)), Array(unique(unwanted).prefix(limit)))
    }

    private static func unique(_ questions: [String]) -> [String] {
        var seen = Set<String>()
        return questions.filter { seen.insert($0.lowercased()).inserted }
    }
}
