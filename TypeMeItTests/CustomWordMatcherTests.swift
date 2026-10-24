import XCTest
@testable import TypeMeIt

final class CustomWordMatcherTests: XCTestCase {
    private let terms = ["typeme.it", "Eliza", "lottie.org", "ack", "fucking", "lib"]

    private func run(_ text: String, confidence: [String: Float] = [:], terms: [String]? = nil) -> CustomWordMatcher.Outcome {
        let words = text.split(separator: " ").map { CustomWordMatcher.Word(text: String($0), confidence: confidence[String($0)]) }
        return CustomWordMatcher.apply(words, terms: terms ?? self.terms)
    }

    func testARunSpellingTheTermIsJoined() {
        XCTAssertEqual(run("When I said type me it, it wrote nothing"), .init(text: "When I said typeme.it, it wrote nothing", fixes: 1))
    }

    func testAJoinedRunKeepsItsConfidenceOutOfIt() {
        XCTAssertEqual(run("say type me it now", confidence: ["type": 0.99, "me": 0.99, "it": 0.99]).text, "say typeme.it now")
    }

    func testListedWordsAreNeverTradedForAnotherTerm() {
        XCTAssertEqual(run("Surely there's a fucking lib for this"), .init(text: "Surely there's a fucking lib for this", fixes: 0))
    }

    func testAShortTermMatchesOnlyExactly() {
        XCTAssertEqual(run("let's do the RAF rate limit", confidence: ["RAF": 0.5]).fixes, 0)
    }

    func testCaseIsCorrectedToTheTermsSpelling() {
        XCTAssertEqual(run("ask eliza about it"), .init(text: "ask Eliza about it", fixes: 1))
    }

    func testAnAlreadyCorrectTermIsNotCounted() {
        XCTAssertEqual(run("ask Eliza about typeme.it"), .init(text: "ask Eliza about typeme.it", fixes: 0))
    }

    func testAnUncertainSoundalikeIsReplaced() {
        XCTAssertEqual(run("changed to TypeMeet", confidence: ["TypeMeet": 0.68]).text, "changed to typeme.it")
        XCTAssertEqual(run("send it to loti", confidence: ["loti": 0.73], terms: ["Lottie"]).text, "send it to Lottie")
    }

    /// Mishearings of the app's name from the user's recordings, with the
    /// confidences the speech model gave them.
    func testTheBuiltInWordCatchesTheAppsName() {
        let terms = CustomWordMatcher.builtInWords
        XCTAssertEqual(run("I'd expect type meet uh", confidence: ["type": 0.85, "meet": 0.79], terms: terms).text, "I'd expect type me it uh")
        XCTAssertEqual(run("create a TypeNit file", confidence: ["TypeNit": 0.70], terms: terms).text, "create a type me it file")
        XCTAssertEqual(run("does uh TypeMeet use", confidence: ["TypeMeet": 0.73], terms: terms).text, "does uh type me it use")
    }

    func testAConfidentSoundalikeBecomesAHintForTheModel() {
        XCTAssertEqual(run("changed to TypeMeet", confidence: ["TypeMeet": 0.98]),
                       .init(text: "changed to TypeMeet", fixes: 0, hints: [.init(heard: "TypeMeet", term: "typeme.it")]))
        XCTAssertEqual(run("check if whisper is running", confidence: ["whisper": 0.99], terms: ["wispr"]).hints,
                       [.init(heard: "whisper", term: "wispr")])
    }

    func testAShortConfidentWordIsNotEvenHinted() {
        XCTAssertEqual(run("the cat sat", confidence: ["cat": 0.99], terms: ["cut"]), .init(text: "the cat sat", fixes: 0))
    }

    func testAnUnknownConfidenceCountsAsUncertain() {
        XCTAssertEqual(run("changed to TypeMeet").text, "changed to typeme.it")
    }

    func testAMishearingTooFarFromTheTermIsLeftAsHeard() {
        XCTAssertEqual(run("Why did it get changed to Titemere", confidence: ["Titemere": 0.74]).fixes, 0)
    }

    func testPunctuationAroundTheRunSurvives() {
        XCTAssertEqual(run("(type me it), then").text, "(typeme.it), then")
    }

    func testDoubledLettersKeyLikeSingleOnes() {
        XCTAssertEqual(run("ping maxo about the blebird release", terms: ["Maxxo", "Bluebird"]).text, "ping Maxxo about the Bluebird release")
    }

    func testPresentTermsAreTheOnesSpelledAsListed() {
        XCTAssertEqual(CustomWordMatcher.present(in: "a fucking lib, and typeme.it.", terms: terms), ["typeme.it", "fucking", "lib"])
        XCTAssertEqual(CustomWordMatcher.present(in: "ask eliza", terms: terms), [])
    }

    func testAnAliasIsReplacedWhenUncertainAndHintedWhenConfident() {
        let terms = [CustomWordMatcher.Term("typeme.it", aliases: ["Titemere"])]
        let uncertain = "changed to Titemere".split(separator: " ").map { CustomWordMatcher.Word(text: String($0), confidence: $0 == "Titemere" ? Float(0.74) : 1) }
        XCTAssertEqual(CustomWordMatcher.apply(uncertain, terms: terms), .init(text: "changed to typeme.it", fixes: 1))
        let confident = "changed to Titemere".split(separator: " ").map { CustomWordMatcher.Word(text: String($0), confidence: 1) }
        XCTAssertEqual(CustomWordMatcher.apply(confident, terms: terms), .init(text: "changed to Titemere", fixes: 0, hints: [.init(heard: "Titemere", term: "typeme.it")]))
    }

    func testStopWordsNeverStandForATerm() {
        XCTAssertEqual(run("this or that", confidence: ["or": 0.5], terms: ["VR"]), .init(text: "this or that", fixes: 0))
        XCTAssertEqual(run("give it to them", confidence: ["to": 0.5, "them": 0.5], terms: ["Totem"]).fixes, 0)
    }

    func testTheBarRisesWithTheSizeOfTheList() {
        XCTAssertEqual(CustomWordMatcher.minSoundSimilarity(terms: 5, confidence: nil), 0.75)
        XCTAssertEqual(CustomWordMatcher.minSoundSimilarity(terms: 50, confidence: nil), 0.8)
        XCTAssertEqual(CustomWordMatcher.minSoundSimilarity(terms: 500, confidence: nil), 0.85)
        XCTAssertEqual(CustomWordMatcher.minSoundSimilarity(terms: 5, confidence: 0.6), 0.65)
        XCTAssertEqual(CustomWordMatcher.minSoundSimilarity(terms: 5, confidence: 0.9), 0.75)
    }

    func testEachExtraWordInARunRaisesTheBar() {
        XCTAssertEqual(CustomWordMatcher.minSoundSimilarity(terms: 5, confidence: nil, words: 2), 0.75 + CustomWordMatcher.runWordPenalty)
        XCTAssertEqual(CustomWordMatcher.minSoundSimilarity(terms: 5, confidence: 0.6, words: 3), 0.65 + 2 * CustomWordMatcher.runWordPenalty)
    }

    func testAnUnsureDictionaryWordIsNotReplacedOnSoundAlone() {
        let words = [CustomWordMatcher.Word(text: "faster", confidence: 0.6)]
        let terms = [CustomWordMatcher.Term("Fastor")]
        XCTAssertEqual(CustomWordMatcher.apply(words, terms: terms), .init(text: "Fastor", fixes: 1))
        XCTAssertEqual(CustomWordMatcher.apply(words, terms: terms, isKnownWord: { $0 == "faster" }),
                       .init(text: "faster", fixes: 0, hints: [.init(heard: "faster", term: "Fastor")]))
    }

    func testADictionaryWordStillMatchesByExactSpellingAndAlias() {
        let known: (String) -> Bool = { _ in true }
        XCTAssertEqual(CustomWordMatcher.apply([.init(text: "lib", confidence: 0.6)], terms: [.init("Lib")], isKnownWord: known).text, "Lib")
        XCTAssertEqual(CustomWordMatcher.apply([.init(text: "faster", confidence: 0.6)], terms: [.init("Fastor", aliases: ["faster"])], isKnownWord: known).text, "Fastor")
    }

    func testAConfidentWordDoesNotJoinAnUnsureOneInASoundMatch() {
        let terms = [CustomWordMatcher.Term("Fastor")]
        let unsureAndConfident = [CustomWordMatcher.Word(text: "fast", confidence: 0.5), .init(text: "orr", confidence: 0.99)]
        XCTAssertEqual(CustomWordMatcher.apply(unsureAndConfident, terms: terms).text, "fast orr")
        let bothUnsure = [CustomWordMatcher.Word(text: "fast", confidence: 0.5), .init(text: "orr", confidence: 0.5)]
        XCTAssertEqual(CustomWordMatcher.apply(bothUnsure, terms: terms).text, "Fastor")
    }

    func testSoundKeys() {
        XCTAssertEqual(CustomWordMatcher.soundKey("typemeit"), "tpmt")
        XCTAssertEqual(CustomWordMatcher.soundKey("typemeet"), "tpmt")
        XCTAssertEqual(CustomWordMatcher.soundKey("kubectl"), "kbktl")
        XCTAssertEqual(CustomWordMatcher.soundKey("cubecontrol"), "kbkntrl")
        XCTAssertEqual(CustomWordMatcher.soundKey("philip"), "flp")
    }

    func testAConfidentWordHintsOnlyWhenItSoundsAllButTheSame() {
        XCTAssertEqual(CustomWordMatcher.apply([.init(text: "changed", confidence: 1)], terms: ["kinda"]).hints, [])
        XCTAssertEqual(CustomWordMatcher.apply([.init(text: "whisper", confidence: 1)], terms: ["wispr"]).hints, [.init(heard: "whisper", term: "wispr")])
    }

    func testOnlyLimitsMatchingToRunsWithTheGivenWords() {
        let words = "Ping Tomash about the name".split(separator: " ").map { CustomWordMatcher.Word(text: String($0), confidence: nil) }
        XCTAssertEqual(CustomWordMatcher.apply(words, terms: [.init("Tomasz"), .init("NAME")], only: ["tomash"]).text, "Ping Tomasz about the name")
    }

    func testApplyHintsWritesTheTermWithItsPunctuation() {
        XCTAssertEqual(CustomWordMatcher.applyHints([.init(heard: "Maxo", term: "Maxxo")], to: "Ping Maxo, now."), "Ping Maxxo, now.")
    }

    func testScoredWordsAttachWhenTheyLineUp() {
        let scored = [Transcriber.Word(text: "hello", confidence: 0.9, start: .zero, end: .zero),
                      Transcriber.Word(text: "world", confidence: .nan, start: .zero, end: .zero)]
        XCTAssertEqual(Transcriber.Transcript(text: "hello world", words: scored).matcherWords,
                       [.init(text: "hello", confidence: 0.9), .init(text: "world", confidence: nil)])
        XCTAssertEqual(Transcriber.Transcript(text: "hello there world", words: scored).matcherWords.map(\.confidence), [nil, nil, nil])
    }

    func testAMeetingRunTakesTheTimeOfTheWordsItReplaced() {
        let heard = [("say", 0.99), ("type", 0.5), ("me", 0.6), ("it,", 0.7), ("now", 0.99)].enumerated().map { i, word in
            Transcriber.Word(text: word.0, confidence: Float(word.1), start: .milliseconds(i * 100), end: .milliseconds(i * 100 + 80))
        }
        XCTAssertEqual(MeetingTranscriber.matched(heard, terms: [.init("typeme.it")], isKnownWord: { _ in false }), [
            heard[0],
            Transcriber.Word(text: "typeme.it,", confidence: 0.5, start: .milliseconds(100), end: .milliseconds(380)),
            heard[4],
        ])
    }

    func testAMeetingKeepsAnUnsureDictionaryWordHeardOnSoundAlone() {
        let heard = [Transcriber.Word(text: "faster", confidence: 0.6, start: .zero, end: .milliseconds(300))]
        XCTAssertEqual(MeetingTranscriber.matched(heard, terms: [.init("Fastor")], isKnownWord: { $0 == "faster" }), heard)
    }
}
