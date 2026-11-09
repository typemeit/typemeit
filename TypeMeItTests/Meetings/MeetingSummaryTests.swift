import Foundation
import Testing
@testable import TypeMeIt

struct MeetingSummaryTests {
    private func turns(_ paragraphs: [(String, String)]) -> [MeetingSummary.Turn] {
        MeetingFixtures.meeting(
            speakers: [Meeting.Speaker(id: "you", name: "You", isYou: true, talkMs: 0), Meeting.Speaker(id: "s1", name: "Ana", isYou: false, talkMs: 0)],
            paragraphs: paragraphs.map { Meeting.Paragraph(speaker: $0.0, startMs: 0, endMs: 0, text: $0.1) }).turns
    }

    @Test func aShortTranscriptIsOnePartOfNamedLines() {
        #expect(MeetingSummary.parts(of: turns([("you", "shall we start"), ("s1", "yes go")]), maxWords: 10)
            == ["You: shall we start\nAna: yes go"])
    }

    @Test func partsBreakAtParagraphsWhenTheyFill() {
        #expect(MeetingSummary.parts(of: turns([("you", "one two three"), ("s1", "four five"), ("you", "six")]), maxWords: 5)
            == ["You: one two three\nAna: four five", "You: six"])
    }

    @Test func aParagraphLongerThanAPartIsCutInside() {
        #expect(MeetingSummary.parts(of: turns([("s1", "a b c d e f g")]), maxWords: 3)
            == ["Ana: a b c", "Ana: d e f", "Ana: g"])
    }

    @Test func aSummaryIsCutAfterItsFourthSentence() {
        let text = "Ana opened. You agreed on the plan. Ben asked about e.g. dates. Cy will follow up. Then lunch. Then more."
        #expect(MeetingSummary.firstSentences(text, max: 4) == "Ana opened. You agreed on the plan. Ben asked about e.g. dates. Cy will follow up.")
        #expect(MeetingSummary.sentenceCount(text) == 6)
    }

    @Test func aShortSummaryIsLeftWhole() {
        #expect(MeetingSummary.firstSentences("One. Two.", max: 4) == "One. Two.")
        #expect(MeetingSummary.sentenceCount("One. Two.") == 2)
    }

    @Test func youIsLowerCasedInsideASentenceOnly() {
        #expect(MeetingSummary.lowercasedYou("You and Rachel discussed Your plan. Rachel asked You to lead it. Yours is next.")
            == "You and Rachel discussed your plan. Rachel asked you to lead it. Yours is next.")
    }

    @Test func noWordsIsNoParts() {
        #expect(MeetingSummary.parts(of: turns([]), maxWords: 10).isEmpty)
    }

    @Test func aTagKeepsItsRawValueInMeetingJSON() throws {
        var meeting = MeetingFixtures.meeting(speakers: [], paragraphs: [])
        meeting.tag = .oneOnOne
        let read = try #require(Meeting.decode(try meeting.encoded()))
        #expect(read.tag == .oneOnOne)
        #expect(String(decoding: try meeting.encoded(), as: UTF8.self).contains("\"oneOnOne\""))
    }

    @Test func aTagThisBuildDoesNotKnowReadsAsOther() throws {
        let tag = try JSONDecoder().decode([MeetingTag].self, from: Data(#"["offsite"]"#.utf8))
        #expect(tag == [.other])
    }

    @Test func aPlainTextAnswerNamesTheFirstKindInIt() {
        #expect(MeetingTag(answer: "interview") == .interview)
        #expect(MeetingTag(answer: "Kind: oneOnOne.") == .oneOnOne)
        #expect(MeetingTag(answer: "**Standup**") == .standup)
        #expect(MeetingTag(answer: "a weekly meeting") == nil)
    }

    @Test func labelsAreShort() {
        #expect(MeetingTag.oneOnOne.label == "1:1")
        #expect(MeetingTag.allHands.label == "all hands")
        #expect(MeetingTag.standup.label == "standup")
    }

    @Test func theTagPromptCountsSpeakersOnlyOnceSplit() {
        let split = [MeetingSummary.Turn(speaker: "You", text: "hi"), MeetingSummary.Turn(speaker: "Ana", text: "hello")]
        #expect(MeetingSummary.tagPrompt(summary: "You and Ana met.", turns: split, words: "hi hello", callName: "Weekly")
            == "<calendar>Weekly</calendar>\n<speakers>2</speakers>\n<summary>You and Ana met.</summary>\n<transcript>\nhi hello\n</transcript>")
        let whole = [MeetingSummary.Turn(speaker: "You", text: "hi"), MeetingSummary.Turn(speaker: "Them", text: "hello")]
        #expect(MeetingSummary.tagPrompt(summary: nil, turns: whole, words: "hi hello", callName: nil)
            == "<transcript>\nhi hello\n</transcript>")
    }
}
