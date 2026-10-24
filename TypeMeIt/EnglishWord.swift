import AppKit

enum EnglishWord {
    /// Whether the English dictionary knows `word` as written or capitalised:
    /// "friday" is Friday, not a name the dictionary lacks.
    @MainActor
    static func isKnown(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        return [word, word.capitalized].contains { form in
            checker.checkSpelling(of: form, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }
}
