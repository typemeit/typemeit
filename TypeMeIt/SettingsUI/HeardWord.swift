import Foundation

/// A run the clean-up dropped, as the history row offers it back. A click on
/// the struck-through words keeps them as a custom word or names the spelling
/// they should have been: the two entries the settings field takes as a word
/// or "heard = word", one click away from the dictation that went wrong.
enum HeardWord {
    /// The run as a term: each word without the punctuation around it, so
    /// "example," is kept as "example" while "typeme.it" stays whole.
    static func term(for run: String) -> String {
        run.split(whereSeparator: \.isWhitespace)
            .map { LocalCleanup.Token(String($0)).core }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Where the run stands with the custom words, read live so every row
    /// shows it, not only the one the click was made on.
    enum Standing: Equatable {
        case unknown
        /// A custom word, kept as heard.
        case kept
        /// A spelling the speech model produces for this custom word.
        case heard(for: String)
    }

    static func standing(of run: String, terms: [CustomWordMatcher.Term]) -> Standing {
        let t = term(for: run)
        guard !t.isEmpty else { return .unknown }
        if terms.contains(where: { $0.text.caseInsensitiveCompare(t) == .orderedSame }) { return .kept }
        if let term = terms.first(where: { $0.aliases.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }) {
            return .heard(for: term.text)
        }
        return .unknown
    }
}
