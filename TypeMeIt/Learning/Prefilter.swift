// Deterministic rules that decide which replacements are worth asking the
// model about. Everything the dictionary documentation says is never learned
// is dropped here, so the model only sees plausible vocabulary and a
// rewritten sentence costs one dropped edit instead of a batch of calls.

import Foundation

enum Prefilter {
    /// Most tokens on either side of a candidate.
    static let maxTokensPerSide = 4
    /// Most characters in a learned entry, matching the Custom Words input.
    static let maxMeantChars = 50
    /// Most candidates taken from a single edit.
    static let maxCandidatesPerEdit = 4
    /// More hunks than this and the edit is a rewrite, not a set of corrections.
    static let maxHunksPerEdit = 6

    /// Speech fillers that never count as vocabulary.
    static let fillerWords: Set<String> = [
        "um", "uh", "uhm", "umm", "uhh", "uhhh", "er", "erm", "ehh", "ehm", "ahm", "hmm", "hm", "mmm",
        "like", "ah", "oh",
    ]

    /// Everyday function words. A candidate made only of these is never
    /// vocabulary, whatever the model might say.
    static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "yet", "for", "of", "to", "in", "on", "at",
        "by", "with", "from", "into", "onto", "over", "under", "about", "after", "before", "between",
        "through", "during", "without", "within", "up", "down", "out", "off", "than", "then", "as",
        "if", "because", "while", "when", "where", "why", "how", "what", "which", "who", "whom",
        "whose", "that", "this", "these", "those", "it", "its", "i", "me", "my", "mine", "we", "us",
        "our", "ours", "you", "your", "yours", "he", "him", "his", "she", "her", "hers", "they",
        "them", "their", "theirs", "is", "am", "are", "was", "were", "be", "been", "being", "do",
        "does", "did", "done", "have", "has", "had", "will", "would", "shall", "should", "can",
        "could", "may", "might", "must", "not", "no", "yes", "very", "just", "also", "too", "only",
        "even", "still", "there", "here", "now", "some", "any", "all", "each", "every", "both", "few",
        "many", "much", "more", "most", "other", "another", "such", "own", "same", "ok", "okay",
        "please", "thanks",
    ]

    /// Why a replacement was not turned into a candidate.
    enum Dropped: Error, Sendable, Equatable {
        case tooLong
        case filler
        case functionWords
        case alreadyKnown
        case denied
    }

    // MARK: Rules

    /// Trim punctuation from the ends of a phrase while keeping inner marks
    /// such as `R&D`, `CI/CD` or `GPT-4`.
    static func trimOuterPunctuation(_ phrase: String) -> String {
        let outer = phrase.unicodeScalars.trimming { scalar in
            !TokenDiff.isAlphanumeric(scalar) && scalar != "&" && scalar != "/" && scalar != "-" && scalar != "'"
        }
        let inner = outer.trimming { scalar in
            scalar == "-" || scalar == "/" || scalar == "'"
        }
        return String(inner)
    }

    private static func phraseKey(_ tokens: [String]) -> String {
        tokens.map(TokenDiff.matchKey).joined()
    }

    private static func allIn(_ list: Set<String>, _ tokens: [String]) -> Bool {
        tokens.allSatisfy { list.contains(TokenDiff.matchKey($0)) }
    }

    private static func anyIn(_ list: Set<String>, _ tokens: [String]) -> Bool {
        tokens.contains { list.contains(TokenDiff.matchKey($0)) }
    }

    /// Apply the rules to one replacement hunk.
    static func candidate(
        _ hunk: TokenDiff.Hunk,
        knownKeys: [String],
        deniedKeys: [String]
    ) -> Result<Candidate, Dropped> {
        if hunk.removed.count > maxTokensPerSide || hunk.inserted.count > maxTokensPerSide {
            return .failure(.tooLong)
        }
        let meant = trimOuterPunctuation(hunk.inserted.joined(separator: " "))
        let heard = trimOuterPunctuation(hunk.removed.joined(separator: " "))
        if meant.unicodeScalars.count > maxMeantChars || meant.isEmpty || heard.isEmpty {
            return .failure(.tooLong)
        }
        if anyIn(fillerWords, hunk.inserted) {
            return .failure(.filler)
        }
        if allIn(functionWords, hunk.inserted) {
            return .failure(.functionWords)
        }
        let key = phraseKey(hunk.inserted)
        if knownKeys.contains(key) {
            return .failure(.alreadyKnown)
        }
        if deniedKeys.contains(key) {
            return .failure(.denied)
        }
        return .success(Candidate(heard: heard, meant: meant))
    }

    /// Match keys for a list of words or phrases, for `knownKeys` and
    /// `deniedKeys`.
    static func keys(_ words: [String]) -> [String] {
        words
            .map { word in
                TokenDiff.tokens(word).map(TokenDiff.matchKey).joined()
            }
            .filter { !$0.isEmpty }
    }
}

extension String.UnicodeScalarView {
    /// Drops scalars matching `predicate` from both ends, like Rust's
    /// `trim_matches`.
    func trimming(where predicate: (Unicode.Scalar) -> Bool) -> SubSequence {
        self[...].trimming(where: predicate)
    }
}

extension Substring.UnicodeScalarView {
    func trimming(where predicate: (Unicode.Scalar) -> Bool) -> Substring.UnicodeScalarView {
        var result = self
        while let first = result.first, predicate(first) {
            result.removeFirst()
        }
        while let last = result.last, predicate(last) {
            result.removeLast()
        }
        return result
    }
}
