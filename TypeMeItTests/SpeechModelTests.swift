import Foundation
import Testing
@testable import TypeMeIt

struct SpeechModelTests {
    private func token(_ text: String, _ confidence: Float, _ start: Double, _ end: Double) -> Transcriber.Token {
        Transcriber.Token(text: text, confidence: confidence, start: start, end: end)
    }

    @Test func wordsSpanTheirTokensAndTakeTheLowestConfidence() {
        let words = Transcriber.words(from: [
            token(" hel", 0.9, 0.0, 0.2), token("lo", 0.6, 0.2, 0.4), token(",", 0.8, 0.4, 0.48),
            token(" world", 0.95, 0.6, 0.9), token(".", 0.99, 0.9, 1.0),
        ])
        #expect(words == [
            Transcriber.Word(text: "hello,", confidence: 0.6, start: .seconds(0.0), end: .seconds(0.48)),
            Transcriber.Word(text: "world.", confidence: 0.95, start: .seconds(0.6), end: .seconds(1.0)),
        ])
    }

    @Test func aFirstTokenWithoutALeadingSpaceStartsAWord() {
        let words = Transcriber.words(from: [token("hi", 0.9, 0, 0.1), token(" there", 0.8, 0.2, 0.3)])
        #expect(words.map(\.text) == ["hi", "there"])
    }

    @Test func blankPiecesAndPaddingAreDropped() {
        let words = Transcriber.words(from: [token("<blank>", 0.1, 0, 0.1), token(" yes", 0.9, 0.1, 0.2), token("<pad>", 0.1, 0.2, 0.3), token("", 0.1, 0.3, 0.4)])
        #expect(words.map(\.text) == ["yes"])
        #expect(words.first?.end == .seconds(0.2))
    }

    @Test func aSpaceOnlyTokenSplitsTheWordAroundIt() {
        let words = Transcriber.words(from: [token(" a", 0.9, 0, 0.1), token(" ", 0.9, 0.1, 0.2), token("b", 0.8, 0.2, 0.3)])
        #expect(words.map(\.text) == ["a", "b"])
    }

    @Test func aTokenWithAnInnerSpaceBecomesTwoWords() {
        let words = Transcriber.words(from: [token(" ice", 0.9, 0, 0.1), token("cream cone", 0.7, 0.1, 0.3)])
        #expect(words.map(\.text) == ["icecream", "cone"])
        #expect(words.map(\.confidence) == [0.7, 0.7])
    }

    @Test func aWordWithNoConfidenceTakesTheNextTokensOne() {
        let words = Transcriber.words(from: [token(" no", .nan, 0, 0.1), token("pe", 0.5, 0.1, 0.2)])
        #expect(words.first?.confidence == 0.5)
    }

    @Test func noTokensMakeNoWords() {
        #expect(Transcriber.words(from: []).isEmpty)
    }

    @Test func textSplitOnWhitespaceStaysOneToOneWithWords() {
        let words = Transcriber.words(from: [token(" it", 0.9, 0, 0.1), token("'s", 0.8, 0.1, 0.2), token(" 3", 0.9, 0.3, 0.4), token(".", 0.9, 0.4, 0.5), token("5", 0.9, 0.5, 0.6)])
        let transcript = Transcriber.Transcript(words: words)
        #expect(transcript.text.split(whereSeparator: \.isWhitespace).map(String.init) == words.map(\.text))
        #expect(transcript.matcherWords.map(\.confidence) == [0.8, 0.9])
    }

    @Test func aMacThatFinishedOnboardingWithoutTheCurrentModelNeedsTheUpgrade() {
        #expect(ModelStore.needsUpgrade(onboardingComplete: true, currentInstalled: false))
        #expect(!ModelStore.needsUpgrade(onboardingComplete: true, currentInstalled: true))
    }

    @Test func aFirstRunGoesThroughOnboardingNotTheUpgrade() {
        #expect(!ModelStore.needsUpgrade(onboardingComplete: false, currentInstalled: false))
    }
}
