// Learning new vocabulary from the user's corrections.
//
// Given a transcript and the user's edited version, find the words that
// changed, keep the ones that could be vocabulary, ask the configured model
// which of those are names, products, acronyms or technical terms, and
// return the spellings to add to the custom words list. Anything that cannot
// be classified is dropped: a missed word costs the user one manual add,
// while a wrong word pollutes their dictionary.

import Foundation

/// One replacement the model will be asked about.
struct Candidate: Sendable, Equatable {
    /// What the speech model wrote.
    var heard: String
    /// What the user changed it to, with surrounding punctuation trimmed.
    var meant: String

    init(heard: String, meant: String) {
        self.heard = heard
        self.meant = meant
    }
}

/// One learned entry: what the speech model wrote and the spelling to add.
struct LearnedPair: Sendable, Equatable {
    var heard: String
    var meant: String

    init(heard: String, meant: String) {
        self.heard = heard
        self.meant = meant
    }
}

/// What the learner already knows and must not learn again.
struct LearnContext: Sendable {
    var customWords: [String]
    var denylist: [String]

    init(customWords: [String] = [], denylist: [String] = []) {
        self.customWords = customWords
        self.denylist = denylist
    }
}

enum Learning {
    /// Normalise a learned entry the way the Custom Words input does: strip
    /// `<`, `>`, `"` and `'`, then collapse runs of whitespace to one space.
    static func normalizeWord(_ word: String) -> String {
        word
            .filter { !"<>\"'".contains($0) }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// True when `meant` is written the way English marks a proper noun inside
    /// `sentence`: a capitalised word that is not in all caps, carries no
    /// digits, and does not open a sentence. The on-device model calls
    /// invented names it has never seen "common words"; the user's
    /// capitalisation says otherwise, and the user typed it.
    static func writtenAsProperNoun(_ meant: String, in sentence: String) -> Bool {
        guard let first = meant.split(whereSeparator: \.isWhitespace).first else {
            return false
        }
        guard let initial = first.first else {
            return false
        }
        if !initial.isUppercase || first.contains(where: isASCIIDigit) {
            return false
        }
        if !first.dropFirst().contains(where: \.isLowercase) {
            return false
        }
        guard let range = sentence.firstRange(of: meant) else {
            return false
        }
        let before = sentence[..<range.lowerBound]
        guard let last = before.last(where: { !$0.isWhitespace }) else {
            return false
        }
        return !".!?:".contains(last)
    }

    /// Tokens of a multi-word replacement that are terms in their own right,
    /// for when the model judged the whole replacement a rewording because it
    /// also carried ordinary words ("NCI C D" corrected to "can CI/CD"). A
    /// token counts when it has a capital after its first letter, a slash,
    /// letters next to digits, or is unknown to the system word list.
    static func termTokens(_ meant: String) -> [String] {
        meant
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                String(token.trimming { ".,;:!?()\"".contains($0) })
            }
            .filter { $0.unicodeScalars.count >= 2 }
            .filter { token in
                let hasLetters = token.unicodeScalars.contains { $0.properties.isAlphabetic }
                let innerCapital = token.dropFirst().contains(where: \.isUppercase)
                let mixedDigits = hasLetters && token.contains(where: isASCIIDigit)
                return hasLetters
                    && (innerCapital
                        || token.contains("/")
                        || mixedDigits
                        || WordList.system.isCoined(token))
            }
    }

    /// Replacement hunks with the pieces of one multi-word correction joined
    /// back together. The diff cuts a phrase wherever a token survives on its
    /// match key, so "get hub actions" corrected to "GitHub Actions" comes
    /// out as "get hub" to "GitHub", and "Sarah Jane Smyth" corrected to
    /// "Sara Jane Smith" as two one-word fixes. A kept token joins the
    /// replacement beside it when the user capitalised it ("actions" to
    /// "Actions"), and a capitalised kept token bridges two replacements
    /// ("Jane"). Function words, a comma or full stop between the pieces,
    /// and a side longer than `Prefilter.maxTokensPerSide` keep them apart.
    static func phrases(_ steps: [TokenDiff.Step]) -> [TokenDiff.Hunk] {
        enum Piece {
            case kept(String, String)
            case changed(TokenDiff.Hunk)
        }
        var pieces: [Piece] = []
        for step in steps {
            switch step {
            case .kept(let heard, let meant):
                pieces.append(.kept(heard, meant))
            case .removed(let token):
                if case .changed(var hunk) = pieces.last {
                    hunk.removed.append(token)
                    pieces[pieces.count - 1] = .changed(hunk)
                } else {
                    pieces.append(.changed(TokenDiff.Hunk(removed: [token], inserted: [])))
                }
            case .inserted(let token):
                if case .changed(var hunk) = pieces.last {
                    hunk.inserted.append(token)
                    pieces[pieces.count - 1] = .changed(hunk)
                } else {
                    pieces.append(.changed(TokenDiff.Hunk(removed: [], inserted: [token])))
                }
            }
        }

        func breaksPhrase(_ token: String) -> Bool {
            guard let last = token.unicodeScalars.last else { return false }
            return ",.;:!?".unicodeScalars.contains(last)
        }
        func capitalised(_ token: String) -> Bool {
            let word = Prefilter.trimOuterPunctuation(token)
            return word.first?.isUppercase == true
                && !Prefilter.functionWords.contains(TokenDiff.matchKey(word))
        }
        func recased(_ heard: String, _ meant: String) -> Bool {
            capitalised(meant) && Prefilter.trimOuterPunctuation(heard) != Prefilter.trimOuterPunctuation(meant)
        }
        func fits(_ hunk: TokenDiff.Hunk, adding removed: Int, _ inserted: Int) -> Bool {
            hunk.removed.count + removed <= Prefilter.maxTokensPerSide
                && hunk.inserted.count + inserted <= Prefilter.maxTokensPerSide
        }

        var out: [TokenDiff.Hunk] = []
        // Pieces before this index belong to a phrase already taken.
        var taken = 0
        var i = 0
        while i < pieces.count {
            guard case .changed(var hunk) = pieces[i], hunk.isReplacement else {
                i += 1
                continue
            }
            // Recased tokens just before it.
            var start = i
            while start > taken, case .kept(let heard, let meant) = pieces[start - 1],
                  !breaksPhrase(meant), recased(heard, meant), fits(hunk, adding: 1, 1) {
                hunk.removed.insert(heard, at: 0)
                hunk.inserted.insert(meant, at: 0)
                start -= 1
            }
            i += 1
            // Recased tokens after it, and a capitalised token followed by
            // another replacement.
            while i < pieces.count, let last = hunk.inserted.last, !breaksPhrase(last) {
                if case .kept(let heard, let meant) = pieces[i], recased(heard, meant), fits(hunk, adding: 1, 1) {
                    hunk.removed.append(heard)
                    hunk.inserted.append(meant)
                    i += 1
                } else if case .changed(let next) = pieces[i], next.isReplacement,
                          fits(hunk, adding: next.removed.count, next.inserted.count) {
                    hunk.removed += next.removed
                    hunk.inserted += next.inserted
                    i += 1
                } else if i + 1 < pieces.count, case .kept(let heard, let meant) = pieces[i],
                          capitalised(meant), !breaksPhrase(meant),
                          case .changed(let next) = pieces[i + 1], next.isReplacement,
                          fits(hunk, adding: 1 + next.removed.count, 1 + next.inserted.count) {
                    hunk.removed += [heard] + next.removed
                    hunk.inserted += [meant] + next.inserted
                    i += 2
                } else {
                    break
                }
            }
            taken = i
            out.append(hunk)
        }
        return out
    }

    /// Candidates from an edit, before the model is consulted. Empty when the
    /// edit is a rewrite, too long to diff, or contains nothing learnable.
    static func candidates(original: String, edited: String, context: LearnContext) -> [Candidate] {
        guard let steps = TokenDiff.steps(original: original, edited: edited) else {
            return []
        }
        if TokenDiff.hunks(steps).count > Prefilter.maxHunksPerEdit {
            return []
        }
        let known = Prefilter.keys(context.customWords)
        let denied = Prefilter.keys(context.denylist)
        var out: [Candidate] = []
        for hunk in phrases(steps) {
            if case .success(let candidate) = Prefilter.candidate(hunk, knownKeys: known, deniedKeys: denied) {
                out.append(candidate)
            }
            if out.count == Prefilter.maxCandidatesPerEdit {
                break
            }
        }
        return out
    }

    /// Entries to add to the dictionary after the user corrected `original`
    /// into `edited`. One model call per edit. Any failure yields nothing.
    static func learn(
        original: String,
        edited: String,
        context: LearnContext,
        check: any VocabularyCheck
    ) async -> [LearnedPair] {
        let candidates = candidates(original: original, edited: edited, context: context)
        if candidates.isEmpty {
            return []
        }
        let kinds: [CorrectionKind]
        do {
            kinds = try await check.check(candidates, context: edited)
        } catch {
            return []
        }
        var learned: [LearnedPair] = []
        func add(heard: String, meant: String) {
            let word = normalizeWord(meant)
            if !word.isEmpty && !learned.contains(where: { $0.meant == word }) {
                learned.append(LearnedPair(heard: heard, meant: word))
            }
        }
        for (candidate, kind) in zip(candidates, kinds) {
            let overridden = kind == .commonWord
                && (writtenAsProperNoun(candidate.meant, in: edited)
                    || WordList.system.isCoined(candidate.meant))
            // The model sometimes files an everyday word ("describe",
            // "cache") as a technical term. A lowercase word the system list
            // knows is one the speech model can already spell, so there is
            // nothing to learn from it.
            let ordinary = kind.isVocabulary && WordList.system.isOrdinary(candidate.meant)
            if ordinary {
                continue
            }
            if kind.isVocabulary || overridden {
                add(heard: candidate.heard, meant: candidate.meant)
            } else {
                let terms = candidate.meant.split(whereSeparator: \.isWhitespace).count > 1
                    ? termTokens(candidate.meant)
                    : []
                for term in terms {
                    add(heard: candidate.heard, meant: term)
                }
            }
        }
        return learned
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character)
    }
}

extension Substring {
    /// Drops characters matching `predicate` from both ends, like Rust's
    /// `trim_matches`.
    func trimming(where predicate: (Character) -> Bool) -> Substring {
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
