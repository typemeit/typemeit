import Foundation
import Testing
@testable import TypeMeIt

struct QuestionSpotterTests {
    private func words(_ text: String, from start: TimeInterval = 0) -> [LiveWord] {
        text.split(separator: " ").enumerated().map { i, word in
            LiveWord(text: String(word), start: start + Double(i), end: start + Double(i) + 0.5)
        }
    }

    @Test func aSentenceEndsAtItsMark() {
        var splitter = SentenceSplitter()
        let sentences = splitter.add(words("Morning. How many calls came in?"))
        #expect(sentences.map { sentence in sentence.map { $0.text }.joined(separator: " ") } == ["Morning.", "How many calls came in?"])
    }

    @Test func wordsWithoutAMarkWaitForTheNextBatch() {
        var splitter = SentenceSplitter()
        let none = splitter.add(words("How many calls"))
        #expect(none.isEmpty)
        #expect(splitter.unfinished.map { $0.text } == ["How", "many", "calls"])
        let sentences = splitter.add(words("came in?", from: 3))
        #expect(sentences.first?.map { $0.text } == ["How", "many", "calls", "came", "in?"])
        #expect(splitter.unfinished.isEmpty)
    }

    @Test func aNumberQuestionIsOffered() {
        #expect(QuestionRule.offers("How many calls did we have last week?", customWords: []))
    }

    @Test func smallTalkIsNot() {
        #expect(!QuestionRule.offers("How was your weekend?", customWords: []))
        #expect(!QuestionRule.offers("Can you see my screen?", customWords: []))
    }

    @Test func aCustomWordOffersTheQuestion() {
        #expect(QuestionRule.offers("Is Acme down again?", customWords: ["acme"]))
    }

    @Test func aCustomWordInsideAnotherWordDoesNot() {
        #expect(!QuestionRule.offers("Is Acmeville down again?", customWords: ["acme"]))
    }

    @Test func aShortQuestionIsNotOffered() {
        #expect(!QuestionRule.offers("How much?", customWords: []))
    }

    @Test func theSameQuestionTwiceInAMinuteIsOfferedOnce() {
        var deduper = QuestionDeduper()
        let first = SpottedQuestion(text: "How many calls did we have last week?", track: .others, start: 10, end: 12)
        let echo = SpottedQuestion(text: "how many calls did we have last week?", track: .mic, start: 10.5, end: 12.5)
        let firstIsNew = deduper.isNew(first)
        let echoIsNew = deduper.isNew(echo)
        #expect(firstIsNew)
        #expect(!echoIsNew)
    }

    @Test func theSameQuestionAfterAMinuteIsOfferedAgain() {
        var deduper = QuestionDeduper()
        let question = SpottedQuestion(text: "How many calls did we have last week?", track: .others, start: 10, end: 12)
        let later = SpottedQuestion(text: question.text, track: .others, start: 100, end: 102)
        let questionIsNew = deduper.isNew(question)
        let laterIsNew = deduper.isNew(later)
        #expect(questionIsNew)
        #expect(laterIsNew)
    }

    @Test func aDifferentQuestionIsNew() {
        var deduper = QuestionDeduper()
        let calls = deduper.isNew(SpottedQuestion(text: "How many calls did we have last week?", track: .others, start: 10, end: 12))
        let table = deduper.isNew(SpottedQuestion(text: "Which table stores the inquiries?", track: .mic, start: 20, end: 22))
        #expect(calls)
        #expect(table)
    }

    @Test func theModelsComeFromTheInitializeResponse() {
        let line = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"models","response":{"models":[{"value":"default","displayName":"Default (recommended)","description":"Opus with 1M context","supportsAutoMode":true},{"value":"haiku","displayName":"Haiku","description":"Fastest"}]}}}"#.utf8)
        #expect(ClaudeModels.models(in: line) == [
            ClaudeModels.Model(value: "default", displayName: "Default (recommended)", description: "Opus with 1M context", supportsAutoMode: true),
            ClaudeModels.Model(value: "haiku", displayName: "Haiku", description: "Fastest", supportsAutoMode: nil),
        ])
    }

    @Test func anyOtherLineHasNoModels() {
        #expect(ClaudeModels.models(in: Data(#"{"type":"system","subtype":"hook_started"}"#.utf8)) == nil)
    }

    @Test func askingTheAppByItsInitialsIsARequest() {
        #expect(WakePhrase.request(in: "TMI, can you check how many calls we had last week?") == "Can you check how many calls we had last week?")
    }

    @Test func theNameSpeltOutOrRunTogetherCounts() {
        #expect(WakePhrase.request(in: "Hey type me it, could you find the inquiries table?") == "Could you find the inquiries table?")
        #expect(WakePhrase.request(in: "T. M. I. would you look up the cap.") == "Would you look up the cap.")
        #expect(WakePhrase.request(in: "Typemeit can you open the ticket") == "Can you open the ticket")
    }

    @Test func theNameLastIsARequest() {
        #expect(WakePhrase.request(in: "what was the final score tmi") == "What was the final score?")
        #expect(WakePhrase.request(in: "Can you check the alerts, Claude?") == "Can you check the alerts?")
        #expect(WakePhrase.request(in: "That was TMI.") == nil)
    }

    @Test func claudeByNameIsARequest() {
        #expect(WakePhrase.request(in: "Claude, what was the last PR merged?") == "What was the last PR merged?")
        #expect(WakePhrase.request(in: "Clawed can you check the alerts") == "Can you check the alerts")
    }

    @Test func theNameBeforeAQuestionIsARequest() {
        #expect(WakePhrase.request(in: "TMI, what was the latest score in the cup final?") == "What was the latest score in the cup final?")
    }

    @Test func theNameWithoutAskingIsNotARequest() {
        #expect(WakePhrase.request(in: "TMI, honestly.") == nil)
        #expect(WakePhrase.request(in: "That was TMI, can you believe it?") == nil)
    }

    @Test func aPastAnswerTeachesTheCheckBothWays() {
        let at = Date(timeIntervalSince1970: 0)
        let entries = [
            QuestionLog.Entry(id: UUID(), at: at, step: .answered, question: "How many calls came in?", answer: .ask),
            QuestionLog.Entry(id: UUID(), at: at.addingTimeInterval(1), step: .answered, question: "Can you see my screen?", answer: .no),
            QuestionLog.Entry(id: UUID(), at: at.addingTimeInterval(2), step: .answered, question: "Is that right?", answer: .ignored),
            QuestionLog.Entry(id: UUID(), at: at.addingTimeInterval(3), step: .checked, question: "Which table?", verdict: .question),
        ]
        let examples = QuestionLog.examples(in: entries, limit: 5)
        #expect(examples.wanted == ["How many calls came in?"])
        #expect(examples.unwanted == ["Can you see my screen?"])
    }

    @Test func theCheckReadsItsOneWordAnswer() {
        #expect(QuestionCheck.verdict(from: ClaudeRun.Answer(text: "ask", seconds: 4, costUSD: 0.003, failed: false)) == .question)
        #expect(QuestionCheck.verdict(from: ClaudeRun.Answer(text: "Skip.", seconds: 4, costUSD: 0.003, failed: false)) == .notAQuestion)
        #expect(QuestionCheck.verdict(from: ClaudeRun.Answer(text: "maybe", seconds: 4, costUSD: 0.003, failed: false)) == .failed)
        #expect(QuestionCheck.verdict(from: ClaudeRun.Answer(text: "Log in to Claude Code", seconds: 0, costUSD: nil, failed: true)) == .failed)
    }
}
