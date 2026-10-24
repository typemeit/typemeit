import Foundation

/// What a search box means everywhere: a literal match that ignores case and
/// accents, so "cafe" finds "Café". The history and meetings lists, the
/// meeting page's highlighter and `typemeit-mcp` (which compiles this file
/// too) all search through it; each picks the fields it searches.
enum TextSearch {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Text folded once, for a list that searches the same rows on every
    /// keystroke: matching is then a byte search.
    struct Folded: Sendable {
        let bytes: [UInt8]

        init(_ text: String) {
            bytes = Array(text.folding(options: TextSearch.options, locale: nil).utf8)
        }

        /// Whether `query` is in this text; an empty query is in nothing.
        func contains(_ query: Folded) -> Bool {
            guard !query.bytes.isEmpty else { return false }
            return bytes.withUnsafeBytes { hay in
                query.bytes.withUnsafeBytes { needle in memmem(hay.baseAddress, hay.count, needle.baseAddress, needle.count) != nil }
            }
        }
    }

    /// Whether `query` is in `text`; an empty query is in nothing.
    static func matches(_ text: String, _ query: String) -> Bool {
        !query.isEmpty && text.range(of: query, options: options) != nil
    }

    /// Every place `query` is in `text`, in order and not overlapping.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var rest = text.startIndex..<text.endIndex
        while let range = text.range(of: query, options: options, range: rest) {
            found.append(range)
            rest = range.upperBound..<text.endIndex
        }
        return found
    }
}
