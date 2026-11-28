import Foundation
import Observation

/// Claude Code reading past dictations for words the speech model likely
/// misheard. Each suggestion waits for the user: approving it fixes the
/// dictations it was found in and, for a name or term, adds it to the
/// dictionary with what was heard as its spelling, so later dictations come
/// out right. A dismissed one is not suggested again.
@MainActor
@Observable
final class WordCheck {
    static let shared = WordCheck()

    /// One word Claude thinks was misheard in one dictation.
    struct Suggestion: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var dictation: UUID
        /// As it appears in the dictation's text.
        var heard: String
        var meant: String
        var why: String
        /// A name, product, acronym or technical term, which joins the dictionary.
        var term: Bool
    }

    /// Where one spelling of a group's word was heard.
    struct Change: Equatable {
        let dictation: UUID
        let heard: String
    }

    /// The suggestions for one word, across every spelling it was heard as
    /// and every dictation it was found in.
    struct Group: Identifiable, Equatable {
        let meant: String
        let why: String
        let term: Bool
        let changes: [Change]
        var id: String { meant.lowercased() }
        /// Each spelling once, in the order found.
        var heard: [String] {
            changes.map(\.heard).reduce(into: []) { spellings, heard in
                if !spellings.contains(heard) { spellings.append(heard) }
            }
        }
    }

    /// A change the user turned down.
    struct Pair: Codable, Hashable, Sendable {
        var heard: String
        var meant: String
    }

    private struct Saved: Codable {
        var checked: Set<UUID> = []
        var dismissed: [Pair] = []
        var suggestions: [Suggestion] = []
    }

    enum Status: Equatable {
        case idle
        case checking(dictations: Int)
        /// Stopped by the user; the run is letting go, and its answer is dropped.
        case stopping
        case failed(String)
    }

    /// Words of dictation one run sends. A tuning knob: more makes a run
    /// slower before anything shows.
    static let wordsPerRun = 4000
    /// Longest a run may take. Not measured.
    static let timeoutSeconds = 300.0
    /// Seconds a clip plays before and after where the heard words are
    /// placed; the place is estimated from the text, so it is padded.
    nonisolated static let clipBefore = 2.0
    nonisolated static let clipAfter = 3.0
    /// Characters of a dictation shown either side of the heard word.
    nonisolated static let excerptContext = 40

    private(set) var status = Status.idle
    private var saved = Saved() {
        didSet { Self.write(saved) }
    }
    @ObservationIgnored private var run: ClaudeRun?

    private static let file = SupportPaths.directory.appendingPathComponent("word-check.json")

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? StoredJSON.decoder.decode(Saved.self, from: data) {
            self.saved = saved
        }
    }

    private static func write(_ saved: Saved) {
        do {
            try StoredJSON.fileEncoder.encode(saved).write(to: file, options: .atomic)
        } catch {
            Log.store.error("Could not write word-check.json: \(error.localizedDescription)")
        }
    }

    /// Claude is turned on in settings and this build can run it.
    static var isOn: Bool { Settings.shared.askClaude && ClaudeRun.isAvailable }

    /// The waiting suggestions whose dictation still holds the heard word.
    func groups(in history: [HistoryEntry]) -> [Group] {
        Self.groups(saved.suggestions, texts: Self.texts(history))
    }

    /// Of `entries`, newest first, the ones a run would send.
    func unchecked(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        entries.filter { $0.question == nil && !saved.checked.contains($0.id) }
    }

    /// Sends the unchecked of `entries`, newest first, up to `wordsPerRun`.
    func check(_ entries: [HistoryEntry]) {
        guard run == nil, status != .stopping else { return }
        let batch = Self.batch(unchecked(entries), words: Self.wordsPerRun)
        guard !batch.isEmpty else { return }
        let settings = Settings.shared
        let input = Self.input(batch, dictionary: settings.matchedWords, dismissed: saved.dismissed)
        guard let run = ClaudeRun.wordCheck(input: input, schema: Self.schema, model: settings.askClaudeModel, timeoutSeconds: Self.timeoutSeconds) else {
            status = .failed("claude code isn't installed")
            return
        }
        self.run = run
        status = .checking(dictations: batch.count)
        Task {
            let answer = await run.answer()
            self.run = nil
            if let ended = Self.status(endingRunIn: status, failure: answer.failed ? answer.text : nil) {
                status = ended
                return
            }
            guard let found = Self.suggestions(from: answer.text, batch: batch) else {
                DebugLog.write("Word check: answer was not the asked-for JSON: \(answer.text.prefix(300))")
                status = .failed("couldn't read claude's answer")
                return
            }
            let dismissed = Set(saved.dismissed.map { Self.pairKey(heard: $0.heard, meant: $0.meant) })
            var next = saved
            next.checked.formUnion(batch.map(\.id))
            next.suggestions += found.filter { !dismissed.contains(Self.pairKey(heard: $0.heard, meant: $0.meant)) }
            saved = next
            status = .idle
            DebugLog.write("Word check: \(counted(found.count, "suggestion")) from \(counted(batch.count, "dictation")) in \(String(format: "%.1f", answer.seconds)) s")
        }
    }

    func stop() {
        status = run == nil ? .idle : .stopping
        run?.cancel()
    }

    /// Where a finished run leaves `status`, or nil when its answer is to be
    /// read: a stopped run goes back to idle whatever it answered, with
    /// nothing marked checked, and a failed one shows its error.
    nonisolated static func status(endingRunIn status: Status, failure: String?) -> Status? {
        if status == .stopping { return .idle }
        return failure.map { .failed($0) }
    }

    /// Fixes each dictation in `group` that still holds the heard word, and
    /// adds a term to the dictionary with the heard word as its spelling.
    func approve(_ group: Group) {
        let store = Store.shared
        for change in group.changes {
            guard let entry = store.history.first(where: { $0.id == change.dictation }),
                  let fixed = Self.replacing(change.heard, with: group.meant, in: entry.displayText) else { continue }
            store.setEdited(id: change.dictation, text: fixed)
        }
        if group.term {
            Settings.shared.addCustomWord(group.meant)
            let word = Settings.shared.matchedWords.first { $0.caseInsensitiveCompare(group.meant) == .orderedSame } ?? group.meant
            for heard in group.heard where heard.caseInsensitiveCompare(word) != .orderedSame {
                store.addAlias(heard: heard, for: word)
            }
        }
        remove(group)
    }

    func dismiss(_ group: Group) {
        saved.dismissed += group.heard.map { Pair(heard: $0, meant: group.meant) }
        remove(group)
    }

    private func remove(_ group: Group) {
        saved.suggestions.removeAll { Self.narrowed(heard: $0.heard, meant: $0.meant)?.meant.lowercased() == group.id }
    }

    // MARK: Pure parts

    nonisolated static func pairKey(heard: String, meant: String) -> String {
        "\(heard.lowercased())\u{1F}\(meant)"
    }

    nonisolated static func texts(_ history: [HistoryEntry]) -> [UUID: String] {
        Dictionary(history.map { ($0.id, $0.displayText) }, uniquingKeysWith: { first, _ in first })
    }

    /// `entries` in order until the next would take the words past `words`;
    /// always the first, however long.
    nonisolated static func batch(_ entries: [HistoryEntry], words: Int) -> [HistoryEntry] {
        var taken: [HistoryEntry] = []
        var total = 0
        for entry in entries {
            let count = entry.wordCount
            if !taken.isEmpty, total + count > words { break }
            taken.append(entry)
            total += count
        }
        return taken
    }

    /// The run's stdin: the user's dictionary, the changes already turned
    /// down, and each dictation numbered from 1.
    nonisolated static func input(_ batch: [HistoryEntry], dictionary: [String], dismissed: [Pair]) -> String {
        var parts: [String] = []
        if !dictionary.isEmpty {
            parts.append("The user's dictionary, spelled as they want:\n\(dictionary.joined(separator: ", "))")
        }
        if !dismissed.isEmpty {
            parts.append("Changes the user already turned down; don't suggest them:\n"
                + dismissed.map { "\($0.heard) → \($0.meant)" }.joined(separator: "\n"))
        }
        let dictations = batch.enumerated().map { i, entry in
            "[\(i + 1)] \(entry.displayText.replacingOccurrences(of: "\n", with: " "))"
        }
        parts.append("Dictations:\n\(dictations.joined(separator: "\n"))")
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// What `--json-schema` asks Claude to answer with.
    nonisolated static let schema = """
        {"type":"object","properties":{"suggestions":{"type":"array","items":{"type":"object","properties":{\
        "dictation":{"type":"integer"},"heard":{"type":"string"},"meant":{"type":"string"},\
        "why":{"type":"string"},"term":{"type":"boolean"}},\
        "required":["dictation","heard","meant","why","term"]}}},"required":["suggestions"]}
        """

    private struct Answer: Decodable {
        struct Item: Decodable {
            let dictation: Int
            let heard: String
            let meant: String
            let why: String
            let term: Bool
        }
        let suggestions: [Item]
    }

    /// The answer's suggestions that name a dictation in `batch` whose text
    /// holds the heard word and that change something; nil when the answer
    /// is not the asked-for JSON.
    nonisolated static func suggestions(from text: String, batch: [HistoryEntry]) -> [Suggestion]? {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(text.utf8)) else { return nil }
        return answer.suggestions.compactMap { item in
            guard batch.indices.contains(item.dictation - 1) else { return nil }
            let entry = batch[item.dictation - 1]
            guard let (heard, meant) = narrowed(heard: item.heard, meant: item.meant),
                  range(of: heard, in: entry.displayText) != nil else { return nil }
            return Suggestion(dictation: entry.id, heard: heard, meant: meant, why: item.why, term: item.term)
        }
    }

    /// The change cut down to the words that differ: words both ends share,
    /// whatever their case, are left as the dictation has them, so "cooper
    /// netties cluster" → "Kubernetes cluster" becomes "cooper netties" →
    /// "Kubernetes". Nil
    /// when nothing differs.
    nonisolated static func narrowed(heard: String, meant: String) -> (heard: String, meant: String)? {
        var heardWords = heard.split(whereSeparator: \.isWhitespace)
        var meantWords = meant.split(whereSeparator: \.isWhitespace)
        func same(_ a: Substring?, _ b: Substring?) -> Bool {
            guard let a, let b else { return false }
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        while heardWords.count > 1, meantWords.count > 1, same(heardWords.first, meantWords.first) {
            heardWords.removeFirst()
            meantWords.removeFirst()
        }
        while heardWords.count > 1, meantWords.count > 1, same(heardWords.last, meantWords.last) {
            heardWords.removeLast()
            meantWords.removeLast()
        }
        let narrowedHeard = heardWords.joined(separator: " "), narrowedMeant = meantWords.joined(separator: " ")
        guard !narrowedHeard.isEmpty, !narrowedMeant.isEmpty, narrowedHeard != narrowedMeant else { return nil }
        return (narrowedHeard, narrowedMeant)
    }

    /// The suggestions grouped by the word meant, whatever its case, in the
    /// order first found, keeping only dictations whose text in `texts`
    /// still holds the heard words.
    nonisolated static func groups(_ suggestions: [Suggestion], texts: [UUID: String]) -> [Group] {
        var order: [String] = []
        var found: [String: [Suggestion]] = [:]
        for s in suggestions {
            guard let (heard, meant) = narrowed(heard: s.heard, meant: s.meant),
                  let text = texts[s.dictation], range(of: heard, in: text) != nil else { continue }
            var narrowed = s
            (narrowed.heard, narrowed.meant) = (heard, meant)
            let key = meant.lowercased()
            if found[key] == nil { order.append(key) }
            if found[key]?.contains(where: { $0.dictation == s.dictation && $0.heard == heard }) != true { found[key, default: []].append(narrowed) }
        }
        return order.compactMap { key in
            guard let items = found[key], let first = items.first else { return nil }
            // A name is often suggested lowercased once and capitalised elsewhere.
            let meant = items.first { $0.meant.contains(where: \.isUppercase) }?.meant ?? first.meant
            return Group(meant: meant, why: first.why, term: items.contains(where: \.term),
                         changes: items.map { Change(dictation: $0.dictation, heard: $0.heard) })
        }
    }

    /// Where `heard` stands as whole words in `text`, matching case.
    nonisolated static func range(of heard: String, in text: String) -> Range<String.Index>? {
        guard let regex = wholeWords(heard) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Range(match.range, in: text)
    }

    /// `text` with every whole-word `heard` replaced by `meant`; nil when it
    /// holds none.
    nonisolated static func replacing(_ heard: String, with meant: String, in text: String) -> String? {
        guard let regex = wholeWords(heard) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard regex.firstMatch(in: text, range: range) != nil else { return nil }
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: meant))
    }

    nonisolated private static func wholeWords(_ phrase: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: phrase))(?![\\p{L}\\p{N}])")
    }

    /// The stretch of a `seconds`-long recording around `heard`, placed by
    /// how far into `text` it starts; nil when `text` does not hold it.
    nonisolated static func clip(of heard: String, in text: String, seconds: Double) -> ClosedRange<Double>? {
        guard let range = range(of: heard, in: text), !text.isEmpty else { return nil }
        let at = Double(text.distance(from: text.startIndex, to: range.lowerBound)) / Double(text.count) * seconds
        return max(0, at - clipBefore)...min(seconds, at + clipAfter)
    }

    /// The dictation's text around the heard word, for a suggestion's row.
    nonisolated static func excerpt(of text: String, around heard: String, context: Int = excerptContext) -> (before: String, after: String)? {
        guard let range = range(of: heard, in: text) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex
        let before = (start == text.startIndex ? "" : "…") + text[start..<range.lowerBound]
        let after = text[range.upperBound..<end] + (end == text.endIndex ? "" : "…")
        return (String(before), String(after))
    }
}
