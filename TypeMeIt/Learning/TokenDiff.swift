// Token-level alignment of a transcript against an edited version (the Rust
// `learning/diff.rs`). Insights counts fixes with it and Learning takes its
// replacement hunks as candidates, so both see the same changes.
//
// Tokens are compared on their match key (alphanumeric, lowercased) so that
// punctuation and capitalisation differences do not register as changes on
// their own. Runs of changed tokens become hunks; a hunk with both a removed
// and an inserted side is a replacement.

import Foundation

enum TokenDiff {
    /// Longest input, in tokens, that is diffed at all. Beyond this an edit is
    /// treated as a rewrite rather than a correction.
    static let maxTokens = 400

    /// One run of changed tokens between the original and the edited text.
    struct Hunk: Equatable, Sendable {
        /// Tokens removed from the original, in order. Empty for a pure insertion.
        var removed: [String]
        /// Tokens inserted by the edit, in order. Empty for a pure deletion.
        var inserted: [String]

        var isReplacement: Bool {
            !removed.isEmpty && !inserted.isEmpty
        }
    }

    /// Lowercased alphanumeric characters of `token`, the same key the custom
    /// words matcher uses. The token is put in NFC first, so a decomposed
    /// "é" keeps its accent and matches the composed one.
    static func matchKey(_ token: String) -> String {
        let canonical = token.unicodeScalars.allSatisfy(\.isASCII) ? token : token.precomposedStringWithCanonicalMapping
        var key = ""
        for scalar in canonical.unicodeScalars where isAlphanumeric(scalar) {
            key += scalar.properties.lowercaseMapping
        }
        return key
    }

    /// Rust's `char::is_alphanumeric`: the `Alphabetic` property or a `N*`
    /// general category.
    static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isAlphabetic {
            return true
        }
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// Rust's `str::split_whitespace`: split on Unicode `White_Space` scalars,
    /// empty pieces dropped. Splitting on scalars rather than characters keeps
    /// a combining mark that follows a space, as the start of the next token.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if ModelText.isWhitespace(scalar) {
                if !current.isEmpty {
                    out.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty {
            out.append(String(current))
        }
        return out
    }

    /// One token of the alignment between the original and the edited text.
    enum Step: Equatable, Sendable {
        /// A token on both sides, as written in the original and in the edit.
        /// The two share a match key but may differ in case or punctuation.
        case kept(String, String)
        case removed(String)
        case inserted(String)
    }

    /// The token alignment of `original` against `edited`, or nil when either
    /// side is too long to diff. Classic LCS over match keys; when a token can
    /// be taken from either side, the removal comes first.
    static func steps(original: String, edited: String) -> [Step]? {
        let a = tokens(original)
        let b = tokens(edited)
        if a.count > maxTokens || b.count > maxTokens {
            return nil
        }
        let ka = a.map(matchKey)
        let kb = b.map(matchKey)

        // LCS table over match keys, flattened row-major with `(m + 1)` columns.
        let n = ka.count
        let m = kb.count
        let width = m + 1
        var lcs = [Int](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * width + j] = ka[i] == kb[j]
                    ? lcs[(i + 1) * width + (j + 1)] + 1
                    : max(lcs[(i + 1) * width + j], lcs[i * width + (j + 1)])
            }
        }

        var out: [Step] = []
        var i = 0
        var j = 0
        while i < n || j < m {
            if i < n && j < m && ka[i] == kb[j] {
                out.append(.kept(a[i], b[j]))
                i += 1
                j += 1
            } else if j >= m || (i < n && lcs[(i + 1) * width + j] >= lcs[i * width + (j + 1)]) {
                out.append(.removed(a[i]))
                i += 1
            } else {
                out.append(.inserted(b[j]))
                j += 1
            }
        }
        return out
    }

    /// Runs of changed steps as hunks, in order.
    static func hunks(_ steps: [Step]) -> [Hunk] {
        var out: [Hunk] = []
        var current: Hunk? = nil
        for step in steps {
            switch step {
            case .kept:
                if let hunk = current {
                    out.append(hunk)
                    current = nil
                }
            case .removed(let token):
                var hunk = current ?? Hunk(removed: [], inserted: [])
                hunk.removed.append(token)
                current = hunk
            case .inserted(let token):
                var hunk = current ?? Hunk(removed: [], inserted: [])
                hunk.inserted.append(token)
                current = hunk
            }
        }
        if let hunk = current {
            out.append(hunk)
        }
        return out
    }

    /// All hunks between `original` and `edited`, or nil when either side is
    /// too long to diff.
    static func hunks(original: String, edited: String) -> [Hunk]? {
        steps(original: original, edited: edited).map { hunks($0) }
    }
}
