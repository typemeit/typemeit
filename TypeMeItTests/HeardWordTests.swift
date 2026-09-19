import XCTest
@testable import TypeMeIt

final class HeardWordTests: XCTestCase {
    private let terms = [
        CustomWordMatcher.Term("typeme.it", aliases: ["Titemere", "type me it"]),
        CustomWordMatcher.Term("parakeet"),
    ]

    func testTheTermIsTheRunWithoutThePunctuationAroundEachWord() {
        XCTAssertEqual(HeardWord.term(for: "example,"), "example")
        XCTAssertEqual(HeardWord.term(for: "“the parrot”"), "the parrot")
    }

    func testPunctuationInsideAWordIsKept() {
        XCTAssertEqual(HeardWord.term(for: "typeme.it,"), "typeme.it")
        XCTAssertEqual(HeardWord.term(for: "don't"), "don't")
    }

    func testARunOfPunctuationIsNoTerm() {
        XCTAssertEqual(HeardWord.term(for: "—"), "")
        XCTAssertEqual(HeardWord.standing(of: "—", terms: terms), .unknown)
    }

    func testACustomWordIsKeptWhateverItsCase() {
        XCTAssertEqual(HeardWord.standing(of: "Parakeet,", terms: terms), .kept)
    }

    func testASpellingOfACustomWordNamesTheWord() {
        XCTAssertEqual(HeardWord.standing(of: "titemere", terms: terms), .heard(for: "typeme.it"))
        XCTAssertEqual(HeardWord.standing(of: "type me it", terms: terms), .heard(for: "typeme.it"))
    }

    func testAnUnlistedRunIsUnknown() {
        XCTAssertEqual(HeardWord.standing(of: "the parrot", terms: terms), .unknown)
    }
}
