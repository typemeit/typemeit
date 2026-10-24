import XCTest
@testable import TypeMeIt

final class OpeningCanTests: XCTestCase {
    func testOpeningAndSubjectVerbIsAsked() {
        XCTAssertEqual(OpeningCan.openingSentence("And you get me all the fields we need for the form, please."), "And you get me all the fields we need for the form, please.")
        XCTAssertEqual(OpeningCan.openingSentence("And I see the screenshot. It's cut off."), "And I see the screenshot.")
        XCTAssertEqual(OpeningCan.openingSentence("And this banner be above the screen shot and stuff"), "And this banner be above the screen shot and stuff")
    }

    func testOnlyTheDictationsOpeningCounts() {
        XCTAssertNil(OpeningCan.openingSentence("It's slow. And you see this happening elsewhere?"))
        XCTAssertNil(OpeningCan.openingSentence("So and you get me the link"))
    }

    func testWordsThatCannotFollowCanAreNotAsked() {
        XCTAssertNil(OpeningCan.openingSentence("And you cannot."))
        XCTAssertNil(OpeningCan.openingSentence("And I was good enough."))
        XCTAssertNil(OpeningCan.openingSentence("And I can try and retrain it"))
        XCTAssertNil(OpeningCan.openingSentence("And we're going to have to update the evals"))
    }

    func testOtherOpeningsAreNotAsked() {
        XCTAssertNil(OpeningCan.openingSentence("And then you chat to it"))
        XCTAssertNil(OpeningCan.openingSentence("And you"))
        XCTAssertNil(OpeningCan.openingSentence("Can you check the logs?"))
        XCTAssertNil(OpeningCan.openingSentence("Andy you get me the link"))
    }

    func testAsCanTurnsTheOpeningFullStopIntoAQuestionMark() {
        XCTAssertEqual(OpeningCan.asCan("And I see the screenshot. It's cut off."), "Can I see the screenshot? It's cut off.")
        XCTAssertEqual(OpeningCan.asCan("And you get me the fields, please."), "Can you get me the fields, please?")
    }

    func testAsCanKeepsOtherEndings() {
        XCTAssertEqual(OpeningCan.asCan("And you see this happening?"), "Can you see this happening?")
        XCTAssertEqual(OpeningCan.asCan("And we remove the header"), "Can we remove the header")
        XCTAssertEqual(OpeningCan.asCan("And you wait..."), "Can you wait...")
    }
}
