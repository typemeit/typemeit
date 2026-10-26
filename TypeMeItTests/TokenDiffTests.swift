import Foundation
import XCTest

@testable import TypeMeIt

final class TokenDiffTests: XCTestCase {
    private func replacements(_ original: String, _ edited: String) -> [(String, String)] {
        TokenDiff.hunks(original: original, edited: edited)!
            .filter(\.isReplacement)
            .map { ($0.removed.joined(separator: " "), $0.inserted.joined(separator: " ")) }
    }

    func testIdenticalTextHasNoHunks() {
        XCTAssertEqual(TokenDiff.hunks(original: "we moved billing", edited: "we moved billing"), [])
    }

    func testSingleWordReplacement() {
        let found = replacements("moved billing to Charge B last week", "moved billing to ChargeBee last week")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].0, "Charge B")
        XCTAssertEqual(found[0].1, "ChargeBee")
    }

    func testPunctuationAndCaseAloneAreNotChanges() {
        XCTAssertEqual(TokenDiff.hunks(original: "hello world", edited: "Hello, world."), [])
    }

    func testInsertionAndDeletionAreNotReplacements() {
        let inserted = TokenDiff.hunks(original: "send the report", edited: "send the full report")!
        XCTAssertEqual(inserted.count, 1)
        XCTAssertFalse(inserted[0].isReplacement)
        let deleted = TokenDiff.hunks(original: "send the full report", edited: "send the report")!
        XCTAssertEqual(deleted.count, 1)
        XCTAssertFalse(deleted[0].isReplacement)
    }

    func testMultipleReplacementsStaySeparate() {
        let found = replacements(
            "Ask pree yanka to move the zen tricks data",
            "Ask Priyanka to move the Zentrix data"
        )
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].0, "pree yanka")
        XCTAssertEqual(found[0].1, "Priyanka")
        XCTAssertEqual(found[1].0, "zen tricks")
        XCTAssertEqual(found[1].1, "Zentrix")
    }

    func testTooLongIsNil() {
        let long = Array(repeating: "word", count: TokenDiff.maxTokens + 1).joined(separator: " ")
        XCTAssertNil(TokenDiff.hunks(original: long, edited: "word"))
    }

    func testMatchKeyKeepsOnlyLowercasedAlphanumerics() {
        XCTAssertEqual(TokenDiff.matchKey("Hello,"), "hello")
        XCTAssertEqual(TokenDiff.matchKey("(5pm)"), "5pm")
        XCTAssertEqual(TokenDiff.matchKey("Ünïcödé!"), "ünïcödé")
        XCTAssertEqual(TokenDiff.matchKey("---"), "")
        XCTAssertEqual(TokenDiff.matchKey("cafe\u{301}"), "caf\u{E9}")
    }

    func testDecomposedAccentMatchesComposed() {
        XCTAssertEqual(TokenDiff.hunks(original: "caf\u{E9} open", edited: "cafe\u{301} open"), [])
    }

    func testConjoiningJamoMatchPrecomposedSyllable() {
        XCTAssertEqual(TokenDiff.hunks(original: "\u{AC00}", edited: "\u{1100}\u{1161}"), [])
    }

    func testCombiningMarkAfterSpaceStartsTheNextToken() {
        XCTAssertEqual(
            TokenDiff.hunks(original: "go \u{301}x", edited: "go y"),
            [TokenDiff.Hunk(removed: ["\u{301}x"], inserted: ["y"])]
        )
    }
}
