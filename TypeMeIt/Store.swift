import Foundation
import Observation

extension HistoryEntry {
    /// The words history shows for it, which insights total by day too.
    var wordCount: Int { Insights.wordCount(displayText) }
}

struct LearnedWord: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var batchId: UUID
    var heard: String
    var meant: String
    var source: String
    var historyId: UUID?
    var learnedAt: Date
    var undone: Bool = false
}

/// history.json and learned-words.json in Application Support. Small enough
/// to hold in memory and rewrite atomically after every change.
@MainActor
@Observable
final class Store {
    static let shared = Store()

    private(set) var history: [HistoryEntry] = [] { didSet { revision &+= 1 } }
    /// Goes up with every change to `history`, so a page can keep what it
    /// works out from it until the history changes.
    private(set) var revision = 0
    private(set) var learned: [LearnedWord] = []

    private var learnedURL: URL { SupportPaths.directory.appendingPathComponent("learned-words.json") }

    private init() {
        try? FileManager.default.createDirectory(at: SupportPaths.directory, withIntermediateDirectories: true)
        history = load(SupportPaths.historyFile) ?? []
        learned = load(learnedURL) ?? []
    }

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try StoredJSON.decoder.decode(T.self, from: data) } catch {
            Log.store.error("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try StoredJSON.fileEncoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.store.error("Could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: History

    /// A limit below 0 keeps no history at all; 0 keeps everything.
    func append(_ entry: HistoryEntry, limit: Int) {
        guard limit >= 0 else { return }
        history.append(entry)
        prune(limit: limit)
        save(history, to: SupportPaths.historyFile)
    }

    /// A limit of 0 keeps everything.
    func prune(limit: Int) {
        guard limit > 0, history.count > limit else { return }
        var excess = history.count - limit
        var kept: [HistoryEntry] = []
        var dropped: [HistoryEntry] = []
        for e in history {
            if excess > 0, !e.starred { excess -= 1; dropped.append(e); continue }
            kept.append(e)
        }
        history = kept
        RecordingArchive.delete(dropped.compactMap(\.recordingFile))
    }

    func update(_ entry: HistoryEntry) {
        guard let i = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history[i] = entry
        save(history, to: SupportPaths.historyFile)
    }

    func delete(id: UUID) {
        delete(ids: [id])
    }

    func delete(ids: Set<UUID>) {
        RecordingArchive.delete(history.filter { ids.contains($0.id) }.compactMap(\.recordingFile))
        history.removeAll { ids.contains($0.id) }
        save(history, to: SupportPaths.historyFile)
    }

    /// Deletes a dictation's audio and keeps its text.
    func deleteAudio(id: UUID) {
        guard let i = history.firstIndex(where: { $0.id == id }), let file = history[i].recordingFile else { return }
        RecordingArchive.delete([file])
        history[i].recordingFile = nil
        save(history, to: SupportPaths.historyFile)
    }

    func deleteAllHistory() {
        history.removeAll()
        RecordingArchive.deleteAll()
        save(history, to: SupportPaths.historyFile)
    }

    func toggleStar(id: UUID) {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        history[i].starred.toggle()
        save(history, to: SupportPaths.historyFile)
    }

    func setEdited(id: UUID, text: String) {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        history[i].edited = text
        history[i].editedAt = Date()
        save(history, to: SupportPaths.historyFile)
    }

    /// What became of the question a dictation asked by name.
    func setQuestion(_ question: Meeting.Question, onDictation id: UUID) {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return }
        history[i].question = question
        save(history, to: SupportPaths.historyFile)
    }

    var newest: HistoryEntry? { history.last }

    // MARK: Learned words

    func appendLearned(_ words: [LearnedWord]) {
        learned.append(contentsOf: words)
        save(learned, to: learnedURL)
    }

    func undoBatch(_ batchId: UUID) -> [String] {
        var undone: [String] = []
        for i in learned.indices where learned[i].batchId == batchId && !learned[i].undone {
            learned[i].undone = true
            undone.append(learned[i].meant)
        }
        save(learned, to: learnedURL)
        return undone
    }

    /// The record behind a custom word that learning added, or nil when the
    /// user typed it in themselves.
    /// Spellings the speech model has produced for `word`, from corrections
    /// that were not undone, plus any the user typed. Newest first.
    func aliases(for word: String) -> [String] {
        var seen: [String] = []
        for r in learned.reversed() where !r.undone && r.meant.caseInsensitiveCompare(word) == .orderedSame {
            let h = r.heard.trimmingCharacters(in: .whitespaces)
            if !h.isEmpty, h.caseInsensitiveCompare(word) != .orderedSame, !seen.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) { seen.append(h) }
        }
        return seen
    }

    /// The custom words with their aliases, as the matcher takes them.
    func terms(for words: [String]) -> [CustomWordMatcher.Term] {
        words.map { CustomWordMatcher.Term($0, aliases: aliases(for: $0)) }
    }

    /// Records that `heard` is how the speech model writes `word`, as a
    /// learned record the user typed rather than corrected.
    func addAlias(heard: String, for word: String) {
        let h = heard.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !aliases(for: word).contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) else { return }
        appendLearned([LearnedWord(batchId: UUID(), heard: h, meant: word, source: "typed", historyId: nil, learnedAt: Date())])
    }

    /// Marks the records that say `heard` is how the speech model writes
    /// `word` undone, leaving the word and its other spellings alone.
    func forgetAlias(heard: String, for word: String) {
        var changed = false
        for i in learned.indices where !learned[i].undone
            && learned[i].meant.caseInsensitiveCompare(word) == .orderedSame
            && learned[i].heard.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(heard) == .orderedSame {
            learned[i].undone = true
            changed = true
        }
        if changed { save(learned, to: learnedURL) }
    }

    func learnedRecord(for word: String) -> LearnedWord? {
        learned.last { !$0.undone && $0.meant.caseInsensitiveCompare(word) == .orderedSame }
    }

    /// Marks every record for `word` undone, so that if the user adds the
    /// same word back by hand it reads as their own.
    func forgetLearned(word: String) {
        var changed = false
        for i in learned.indices where !learned[i].undone && learned[i].meant.caseInsensitiveCompare(word) == .orderedSame {
            learned[i].undone = true
            changed = true
        }
        if changed { save(learned, to: learnedURL) }
    }
}
