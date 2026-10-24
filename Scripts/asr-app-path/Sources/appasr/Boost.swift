import FluidAudio
import Foundation

/// FluidAudio's CTC vocabulary boosting around the app's Transcriber. run.sh patches
/// `Transcriber.run` to call `Boost.rescored` when a session is set, so the rest of the
/// app path (model, timings, word rows) is the app's own.
enum Boost {
    nonisolated(unsafe) static var session: VocabularyBoostingSession?
    nonisolated(unsafe) static var rescoreMs: [Double] = []

    static func load(terms: [CustomWordMatcher.Term]) async throws {
        let models = try await CtcModels.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
        let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases) })
        session = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: models)
    }

    /// The transcript with FluidAudio's replacements applied. Words the rescorer left alone keep
    /// the model's confidence; a replaced word counts as sure (acoustic evidence chose it).
    static func rescored(heard: [Transcriber.Word], text: String, timings: [TokenTiming], pcm: [Float]) async -> Transcriber.Transcript {
        guard let session else { return Transcriber.Transcript(words: heard) }
        let started = ContinuousClock.now
        let output = await session.rescore(text: text, tokenTimings: timings, audioSamples: pcm)
        rescoreMs.append(Double((ContinuousClock.now - started).components.attoseconds) / 1e15 + Double((ContinuousClock.now - started).components.seconds) * 1000)
        guard let output, output.wasModified else { return Transcriber.Transcript(words: heard) }
        let newTexts = output.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let oldTexts = heard.map(\.text)
        let difference = newTexts.difference(from: oldTexts)
        var inserted = Set<Int>()
        for change in difference { if case .insert(let offset, _, _) = change { inserted.insert(offset) } }
        var removed = Set<Int>()
        for change in difference { if case .remove(let offset, _, _) = change { removed.insert(offset) } }
        let kept = heard.indices.filter { !removed.contains($0) }
        var words: [Transcriber.Word] = []
        var keptIndex = 0
        var lastEnd = Duration.zero
        for (offset, newText) in newTexts.enumerated() {
            if inserted.contains(offset) {
                let start = keptIndex < kept.count ? heard[kept[keptIndex]].start : lastEnd
                words.append(Transcriber.Word(text: newText, confidence: 1, start: min(start, lastEnd), end: start))
            } else if keptIndex < kept.count {
                words.append(heard[kept[keptIndex]])
                lastEnd = heard[kept[keptIndex]].end
                keptIndex += 1
            }
        }
        return Transcriber.Transcript(words: words)
    }
}
