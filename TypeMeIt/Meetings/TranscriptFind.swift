import Foundation

/// Where a search lands in a transcript: every match, paragraph by
/// paragraph, as the meetings list's search finds them.
enum TranscriptFind {
    struct Hit: Equatable {
        let paragraph: Int
        let range: Range<String.Index>
    }

    static func hits(of query: String, in paragraphs: [String]) -> [Hit] {
        paragraphs.enumerated().flatMap { i, text in TextSearch.ranges(of: query, in: text).map { Hit(paragraph: i, range: $0) } }
    }
}
