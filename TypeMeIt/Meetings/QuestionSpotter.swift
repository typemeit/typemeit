import Foundation

/// One word of a meeting's live transcript, timed in seconds from the start
/// of the meeting.
struct LiveWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// A question someone asked during a meeting that the app offers to send to
/// Claude.
struct SpottedQuestion: Equatable, Sendable {
    enum Track: String, Sendable { case mic, others }
    let text: String
    let track: Track
    let start: TimeInterval
    let end: TimeInterval
    /// Said to the app by name ("TMI, can you…"), so it skips the check; it
    /// is still only asked once the user says ask.
    var addressed = false
}

/// The user asking the app, or Claude, by name: "TMI, can you…", "Claude,
/// could you…", or the name before a question ("type me it, what was…?"). Speech recognition writes the name several ways, so each is a word
/// sequence after punctuation is stripped from every word.
enum WakePhrase {
    private static let names: [[String]] = [["tmi"], ["t", "m", "i"], ["type", "me", "it"], ["typemeit"], ["type", "meet"],
                                            ["claude"], ["clawed"]]
    private static let greetings: Set<String> = ["hey", "ok", "okay"]
    private static let asks: Set<String> = ["can", "could", "would", "will"]
    /// How a question can open when the name comes last and the stream
    /// dropped its question mark: "what was the score TMI".
    private static let questionWords: Set<String> = ["what", "who", "when", "where", "why", "how", "which",
                                                     "is", "are", "was", "were", "do", "does", "did", "have", "has"]

    /// The request after the name, or nil when the sentence does not start
    /// by asking the app.
    static func request(in sentence: String) -> String? {
        let tokens = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        let words = tokens.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        return leading(tokens, words, sentence) ?? trailing(tokens, words, sentence)
    }

    /// The name first: "TMI, can you…", "Claude, what was…?".
    private static func leading(_ tokens: [String], _ words: [String], _ sentence: String) -> String? {
        var at = words.first.map { greetings.contains($0) } == true ? 1 : 0
        guard let name = names.first(where: { Array(words.dropFirst(at).prefix($0.count)) == $0 }) else { return nil }
        at += name.count
        guard words.count > at + 1 else { return nil }
        let asksYou = asks.contains(words[at]) && words[at + 1] == "you"
        guard asksYou || sentence.hasSuffix("?") else { return nil }
        return capitalised(tokens[at...].joined(separator: " "))
    }

    /// The name last: "what was the score, TMI?".
    private static func trailing(_ tokens: [String], _ words: [String], _ sentence: String) -> String? {
        guard let name = names.first(where: { Array(words.suffix($0.count)) == $0 }) else { return nil }
        let before = tokens.dropLast(name.count)
        guard before.count >= 2, let first = words.first else { return nil }
        let opensAsQuestion = questionWords.contains(first) || (asks.contains(first) && words.dropFirst().first == "you")
        guard opensAsQuestion || sentence.hasSuffix("?") else { return nil }
        let request = before.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return capitalised(request + "?")
    }

    private static func capitalised(_ request: String) -> String {
        request.prefix(1).uppercased() + request.dropFirst()
    }
}

/// Splits one track's live words into sentences and hands back the ones that
/// end in a question mark. Words arrive in order and are never revised.
struct SentenceSplitter {
    private var pending: [LiveWord] = []

    /// The sentences the new words complete, oldest first.
    mutating func add(_ words: [LiveWord]) -> [[LiveWord]] {
        var sentences: [[LiveWord]] = []
        for word in words {
            pending.append(word)
            if let last = word.text.last, ".?!".contains(last) {
                sentences.append(pending)
                pending = []
            }
        }
        return sentences
    }

    /// Words since the last sentence end, for a stream that is about to restart.
    var unfinished: [LiveWord] { pending }
}

/// Whether a question looks like one an assistant with the company's data and
/// code could answer: it asks for a number, a record or how something works,
/// or it names one of the user's own words. A rule like this was right about
/// a third of the time on meetings it had not seen, so the app offers the
/// question and the user decides whether to ask.
enum QuestionRule {
    static let minimumWords = 3

    private static var phrases: Regex<AnyRegexOutput> {
        try! Regex(
            #"\b(how many|how much|what percent\w*|what('s| is) (the|our) (number|count|rate|cost|volume|split|status)"#
                + #"|do we (have|store|track|know|get|use)|is there (a|an|any)|are there any"#
                + #"|which (table|service|repo|field|column|endpoint)"#
                + #"|where (is|are|does|do) .{0,30}(stored|live|come from|set)|how does .{0,40} work"#
                + #"|database|table|column|endpoint|api|ticket|dashboard)\b"#
        ).ignoresCase()
    }

    static func offers(_ question: String, customWords: [String]) -> Bool {
        let words = question.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
        guard words.count >= minimumWords else { return false }
        if question.contains(phrases) { return true }
        return customWords.contains { custom in
            words.contains { $0.compare(custom, options: .caseInsensitive) == .orderedSame }
        }
    }
}

/// Drops a question that repeats one offered a moment ago: the same question
/// asked twice, or the far end's question heard again through the mic.
struct QuestionDeduper {
    static let window: TimeInterval = 60
    static let sameShare = 0.6

    private var offered: [(words: Set<String>, end: TimeInterval)] = []

    mutating func isNew(_ question: SpottedQuestion) -> Bool {
        let words = Self.words(of: question.text)
        offered.removeAll { question.end - $0.end > Self.window }
        let repeats = offered.contains { earlier in
            let shared = Double(words.intersection(earlier.words).count)
            return shared / Double(max(1, min(words.count, earlier.words.count))) >= Self.sameShare
        }
        if repeats { return false }
        offered.append((words, question.end))
        return true
    }

    static func words(of text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }
}
