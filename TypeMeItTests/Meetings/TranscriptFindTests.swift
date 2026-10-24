import Testing
@testable import TypeMeIt

struct TranscriptFindTests {
    @Test func hitsAreInReadingOrder() {
        let hits = TranscriptFind.hits(of: "ship", in: ["we ship friday", "nothing", "ship it, then ship again"])
        #expect(hits.map(\.paragraph) == [0, 2, 2])
    }
}
