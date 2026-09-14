import Testing
@testable import TypeMeIt

struct LogTests {
    @Test func excerptKeepsShortTextWhole() {
        #expect(Log.excerpt("hello there") == "hello there")
    }

    @Test func excerptJoinsLinesAndRunsOfSpaces() {
        #expect(Log.excerpt("one\ntwo   three\t four") == "one two three four")
    }

    @Test func excerptCutsLongTextWithAnEllipsis() {
        let text = String(repeating: "a", count: 41)
        #expect(Log.excerpt(text) == String(repeating: "a", count: 40) + "…")
    }

    @Test func excerptCountsCharactersNotBytes() {
        let text = String(repeating: "é", count: 40)
        #expect(Log.excerpt(text) == text)
    }
}
