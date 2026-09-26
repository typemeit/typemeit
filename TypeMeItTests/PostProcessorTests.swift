import XCTest
@testable import TypeMeIt

final class PostProcessorTests: XCTestCase {
    func testLostOpeningRejectsADroppedStart() {
        XCTAssertTrue(PostProcessor.lostOpening(transcript: "that will be $25 please", output: "$25 please."))
        XCTAssertTrue(PostProcessor.lostOpening(transcript: "so I think we should ship it", output: "We should ship it on Friday."))
    }

    func testLostOpeningAllowsOneAddedWordAndPunctuation() {
        XCTAssertFalse(PostProcessor.lostOpening(transcript: "that will be $25 please", output: "That will be $25, please."))
        XCTAssertFalse(PostProcessor.lostOpening(transcript: "what is the time", output: "Hey, what is the time?"))
        XCTAssertFalse(PostProcessor.lostOpening(transcript: "", output: "anything"))
        XCTAssertFalse(PostProcessor.lostOpening(transcript: "their going to the shops", output: "They're going to the shops."))
        XCTAssertFalse(PostProcessor.lostOpening(transcript: "were meeting at there house", output: "We're meeting at their house."))
    }

    func testLostOpeningAllowsTheOpeningNumberAsDigits() {
        XCTAssertFalse(PostProcessor.lostOpening(transcript: "One hundred and thirty four", output: "134."))
        XCTAssertFalse(PostProcessor.lostOpening(transcript: "a hundred and thirty four", output: "134."))
        XCTAssertFalse(PostProcessor.lostOpening(transcript: "twenty five percent of them left", output: "25% of them left."))
        XCTAssertTrue(PostProcessor.lostOpening(transcript: "twenty five people came", output: "People came."))
    }

    func testLostOpeningNeedsTheSecondWordAfterACorrectedFirst() {
        XCTAssertTrue(PostProcessor.lostOpening(transcript: "she said ship it", output: "Ship it."))
    }

    func testGateLeavesPunctuatedAndUnpunctuatedTextToCode() {
        XCTAssertNil(PostProcessor.reasonForModel("It was cold out there.", hints: [], screenTerms: []))
        XCTAssertNil(PostProcessor.reasonForModel("it was cold out there and we left", hints: [], screenTerms: []))
    }

    func testGateCallsTheModelForWhatOnlyItCanDo() {
        let hint = CustomWordMatcher.Hint(heard: "whisper", term: "wispr")
        XCTAssertEqual(PostProcessor.reasonForModel("Is whisper running?", hints: [hint], screenTerms: []), "custom word hint")
        XCTAssertEqual(PostProcessor.reasonForModel("Dear Sam comma thanks", hints: [], screenTerms: []), "spoken punctuation")
        XCTAssertEqual(PostProcessor.reasonForModel("I don't f a little bit", hints: [], screenTerms: []), "stranded letter")
        XCTAssertEqual(PostProcessor.reasonForModel("send the the file", hints: [], screenTerms: []), "repeated word")
        XCTAssertNil(PostProcessor.reasonForModel("very very cold", hints: [], screenTerms: []))
    }

    func testGateCallsTheModelForAScreenTermOnlyWhenHeardAsANonWord() {
        XCTAssertEqual(PostProcessor.reasonForModel("Ping Tomash about it", hints: [], screenTerms: ["Tomasz"], unknownWords: ["tomash"]), "sounds like Tomasz")
        XCTAssertNil(PostProcessor.reasonForModel("Read the file", hints: [], screenTerms: ["READY"], unknownWords: []))
    }

    func testRestoreKeptWordsPutsBackAWordTheModelDeleted() {
        XCTAssertEqual(PostProcessor.restoreKeptWords(transcript: "it was like really cold out there", output: "It was really cold out there."), "It was like really cold out there.")
        XCTAssertEqual(PostProcessor.restoreKeptWords(transcript: "it was cold", output: "It was cold."), "It was cold.")
    }

    func testCapitaliseOpeningOnlyTouchesAPlainLowercaseWord() {
        XCTAssertEqual(PostProcessor.capitaliseOpening("it was cold"), "It was cold")
        XCTAssertEqual(PostProcessor.capitaliseOpening("iPhone sales"), "iPhone sales")
        XCTAssertEqual(PostProcessor.capitaliseOpening("e.g. this"), "e.g. this")
    }

    func testJoinSpelledLettersMakesAcronyms() {
        XCTAssertEqual(ModelText.joinSpelledLetters("lottie h q signed with anthropic"), "lottie HQ signed with anthropic")
        XCTAssertEqual(ModelText.joinSpelledLetters("send it as a p d f to the c e o"), "send it as a PDF to the CEO")
        XCTAssertEqual(ModelText.joinSpelledLetters("I don't f a little bit"), "I don't f a little bit")
        XCTAssertEqual(ModelText.joinSpelledLetters("a b test and I a m"), "a b test and I a m")
    }

    func testFuseTermsJoinsSpokenWordsIntoATerm() {
        XCTAssertEqual(ModelText.fuseTerms("Lottie HQ signed with Anthropic.", terms: ["LottieHQ", "Anthropic"]), "LottieHQ signed with Anthropic.")
        XCTAssertEqual(ModelText.fuseTerms("Bump max retries to 5 in parse config.", terms: ["MAX_RETRIES", "parse_config.ts", "parse_config"]), "Bump MAX_RETRIES to 5 in parse_config.")
        XCTAssertEqual(ModelText.fuseTerms("use the state hook", terms: ["useState"]), "use the state hook")
    }

    func testCurrencySymbols() {
        XCTAssertEqual(ModelText.currencySymbols("That will be 25 dollars and 3.50 euros, not 50 pounds."), "That will be $25 and €3.50, not £50.")
    }
}
