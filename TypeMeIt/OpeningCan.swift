import Foundation
import FoundationModels

/// A request that opens a dictation with a quick, unstressed "can" ("c'n you
/// check the logs") often comes back from the speech model as "And you check
/// the logs". The speech model is as sure of that "And" as of a real one, and
/// decoding the same clip again flips between the two, so only the sentence
/// can settle it. When a dictation opens "And" + subject + verb, the model is
/// shown the sentence with its first word blanked and picks "can" or "and".
/// Shown both versions side by side instead, it picked whichever came second.
enum OpeningCan {
    static let subjects: Set<String> = ["i", "you", "we", "they", "he", "she", "it", "this"]

    /// Words that cannot follow "Can <subject>": the modals and the finite
    /// forms of be, have and do ("And you cannot", "And I was").
    static let notAfterCan: Set<String> = [
        "can", "cannot", "could", "will", "would", "shall", "should", "may", "might", "must",
        "am", "is", "are", "was", "were", "has", "had", "does", "did",
    ]

    /// The end of the first sentence: a stop followed by a space or the end.
    nonisolated(unsafe) static let sentenceEnd = /[.?!](?=\s|$)/

    /// The dictation's first sentence when it opens "And <subject> <verb>"
    /// and could have been "Can …", or nil.
    static func openingSentence(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = trimmed.firstMatch(of: sentenceEnd).map { String(trimmed[..<$0.range.upperBound]) } ?? trimmed
        let words = sentence.split(whereSeparator: \.isWhitespace).prefix(3).map(String.init)
        guard words.count == 3, words[0] == "And", subjects.contains(words[1].lowercased()) else { return nil }
        let verb = words[2].lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard !verb.isEmpty, verb.allSatisfy(\.isLetter), !notAfterCan.contains(verb) else { return nil }
        return sentence
    }

    /// The text with its opening "And" as "Can", and the first sentence's
    /// full stop as a question mark. An ellipsis stays.
    static func asCan(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = "Can" + trimmed.dropFirst("And".count)
        if let stop = out.firstMatch(of: sentenceEnd), out[stop.range] == ".",
           out[..<stop.range.lowerBound].last != "." {
            out.replaceSubrange(stop.range, with: "?")
        }
        return out
    }

    @Generable enum FirstWord { case can, and }
    @Generable struct Choice: Sendable { let firstWord: FirstWord }

    static let blank = "___"

    static let instructions = """
    You get one sentence from a dictation. Its first word is missing, shown as \(blank). The missing word is either "can" or "and"; the speech-to-text model could not tell which, because a quick "can" sounds like "and".

    Answer can when the sentence only makes sense as a request or a question: asking someone to do something, or asking whether something is possible or allowed. "\(blank) you check the logs" → can, "\(blank) we move the about section" → can, "\(blank) I see the screenshot" → can.
    Answer and when the sentence reads as a statement: someone saying what they think, feel, did or said. "\(blank) I think that is fine" → and, "\(blank) we went home after that" → and, "\(blank) you know what he said" → and.
    """

    /// The text with its opening settled. Unchanged when it does not open
    /// "And <subject> <verb>", or the model is unavailable, refuses or fails.
    static func resolve(_ text: String, model: SystemLanguageModel) async -> String {
        guard let sentence = openingSentence(text), case .available = model.availability else { return text }
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let choice = try await session.respond(to: blank + sentence.dropFirst("And".count), generating: Choice.self,
                                                   options: GenerationOptions(sampling: .greedy))
            Log.postProcess.info("Opening \"And\" read as \(choice.content.firstWord == .can ? "Can" : "And")")
            return choice.content.firstWord == .can ? asCan(text) : text
        } catch {
            Log.postProcess.notice("Opening can-or-and check failed: \(error.localizedDescription)")
            return text
        }
    }
}
