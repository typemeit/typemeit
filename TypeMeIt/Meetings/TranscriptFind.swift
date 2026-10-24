import Foundation

/// Where a search lands in a transcript: every match, paragraph by
/// paragraph, ignoring case as the meetings list's search does.
enum TranscriptFind {
    struct Hit: Equatable {
        let paragraph: Int
        let range: Range<String.Index>
    }

    static func hits(of query: String, in paragraphs: [String]) -> [Hit] {
        paragraphs.enumerated().flatMap { i, text in ranges(of: query, in: text).map { Hit(paragraph: i, range: $0) } }
    }

    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var rest = text.startIndex..<text.endIndex
        while let range = text.range(of: query, options: .caseInsensitive, range: rest) {
            found.append(range)
            rest = range.upperBound..<text.endIndex
        }
        return found
    }
}
