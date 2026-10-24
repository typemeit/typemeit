import Testing
@testable import TypeMeIt

struct TranscriptFindTests {
    private func found(_ query: String, in text: String) -> [String] {
        TranscriptFind.ranges(of: query, in: text).map { String(text[$0]) }
    }

    @Test func matchesIgnoreCase() {
        #expect(found("price", in: "Price first, then the price page.") == ["Price", "price"])
    }

    @Test func matchesDoNotOverlap() {
        #expect(found("aa", in: "aaaa") == ["aa", "aa"])
    }

    @Test func emptyQueryFindsNothing() {
        #expect(found("", in: "anything").isEmpty)
    }

    @Test func hitsAreInReadingOrder() {
        let hits = TranscriptFind.hits(of: "ship", in: ["we ship friday", "nothing", "ship it, then ship again"])
        #expect(hits.map(\.paragraph) == [0, 2, 2])
    }
}
