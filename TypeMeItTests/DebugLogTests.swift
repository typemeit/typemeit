import Foundation
import Testing
@testable import TypeMeIt

struct DebugLogTests {
    @Test func excerptKeepsShortTextWhole() {
        #expect(DebugLog.excerpt("hello there") == "hello there")
    }

    @Test func excerptJoinsLinesAndRunsOfSpaces() {
        #expect(DebugLog.excerpt("one\ntwo   three\t four") == "one two three four")
    }

    @Test func excerptCutsLongTextWithAnEllipsis() {
        let text = String(repeating: "a", count: 41)
        #expect(DebugLog.excerpt(text) == String(repeating: "a", count: 40) + "…")
    }

    @Test func excerptCountsCharactersNotBytes() {
        let text = String(repeating: "é", count: 40)
        #expect(DebugLog.excerpt(text) == text)
    }

    @Test func trimmedLeavesSmallDataAlone() {
        let data = Data("one\ntwo\n".utf8)
        #expect(DebugLog.trimmed(data, to: 100) == data)
    }

    @Test func trimmedKeepsTheTailFromALineStart() {
        let data = Data("first line\nsecond line\nthird line\n".utf8)
        #expect(String(decoding: DebugLog.trimmed(data, to: 16), as: UTF8.self) == "third line\n")
    }

    @Test func trimmedWithNoNewlineInTheTailKeepsTheTail() {
        let data = Data("abcdefghij".utf8)
        #expect(String(decoding: DebugLog.trimmed(data, to: 4), as: UTF8.self) == "ghij")
    }
}
