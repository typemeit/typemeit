import Testing
@testable import TypeMeIt

struct TranscriptMergeTests {
    @Test func interleavingTwoTracksInTimeOrder() {
        let you = TrackWords(role: "you", words: [
            .at("hi", 0, 500),
        ])
        let them = TrackWords(role: "them", words: [
            .at("hey", 200, 700),
        ])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [
            Meeting.Paragraph(speaker: "you", startMs: 0, endMs: 500, text: "hi"),
            Meeting.Paragraph(speaker: "them", startMs: 200, endMs: 700, text: "hey"),
        ])
    }

    @Test func twoPeopleTalkingAtOnceStayTwoParagraphs() {
        let you = TrackWords(role: "you", words: (0..<4).map {
            .at("a\($0)", $0 * 400, $0 * 400 + 300)
        })
        let them = TrackWords(role: "them", words: (0..<4).map {
            .at("b\($0)", $0 * 400 + 100, $0 * 400 + 350)
        })
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [
            Meeting.Paragraph(speaker: "you", startMs: 0, endMs: 1500, text: "a0 a1 a2 a3"),
            Meeting.Paragraph(speaker: "them", startMs: 100, endMs: 1550, text: "b0 b1 b2 b3"),
        ])
    }

    /// Words every 400 ms, 300 ms long, from `fromMs` up to `toMs`.
    private func run(_ prefix: String, fromMs: Int, toMs: Int) -> [Transcriber.Word] {
        stride(from: fromMs, to: toMs, by: 400).enumerated().map { i, ms in
            .at("\(prefix)\(i)", ms, ms + 300)
        }
    }

    @Test func aTurnIsCutWhereTheOtherSpeakerCutsIn() {
        let them = TrackWords(role: "them", words: run("b", fromMs: 0, toMs: 6000))
        let you = TrackWords(role: "you", words: run("a", fromMs: 3100, toMs: 4400))
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs.map(\.speaker) == ["them", "you", "them"])
        #expect(paragraphs.map(\.startMs) == [0, 3100, 3200])
        #expect(paragraphs[0].text == "b0 b1 b2 b3 b4 b5 b6 b7")
    }

    @Test func aLastWordTheReplyRunsOverStaysInTheTurn() {
        let them = TrackWords(role: "them", words: run("b", fromMs: 0, toMs: 4000))
        let you = TrackWords(role: "you", words: run("a", fromMs: 3500, toMs: 5000))
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs.map(\.speaker) == ["them", "you"])
    }

    @Test func anUmOnItsOwnIsDroppedAndCutsNothing() {
        let them = TrackWords(role: "them", words: run("b", fromMs: 0, toMs: 6000))
        let you = TrackWords(role: "you", words: [.at("Um,", 3100, 3300)])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs.map(\.speaker) == ["them"])
        #expect(paragraphs[0].endMs == 5900)
    }

    @Test func dictationRemovesAMicWord() {
        let you = TrackWords(role: "you", words: [
            .at("hello", 0, 500),
        ])
        let paragraphs = TranscriptMerge.paragraphs(
            tracks: [you], segments: nil,
            dictations: [Meeting.Span(startMs: 0, endMs: 1000)], gap: .seconds(2)
        )
        #expect(paragraphs == [])
    }

    @Test func aPauseAloneDoesNotSplitAParagraph() {
        // The 25 September call: a 2.4 s search for a word, mid-sentence.
        let them = TrackWords(role: "them", words: [
            .at("the ostentatious", 0, 500),
            .at("improv thing?", 3000, 3500),
        ])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: nil, dictations: [], gap: .seconds(1))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "them", startMs: 0, endMs: 3500, text: "the ostentatious improv thing?")])
    }

    @Test func anotherSpeakerBetweenPausesKeepsTheParagraphsApart() {
        let them = TrackWords(role: "them", words: [
            .at("a", 0, 500),
            .at("c", 6000, 6500),
        ])
        let you = TrackWords(role: "you", words: [.at("b", 3000, 3500)])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(1))
        #expect(paragraphs.map(\.text) == ["a", "b", "c"])
    }

    @Test func anEmptyTrackContributesNothing() {
        let you = TrackWords(role: "you", words: [])
        let them = TrackWords(role: "them", words: [
            .at("hi", 0, 500),
        ])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "them", startMs: 0, endMs: 500, text: "hi")])
    }

    @Test func aWordBetweenTwoSegmentsTakesTheNearestWithinOneSecond() {
        let them = TrackWords(role: "them", words: [
            .at("hi", 1300, 1700),
        ])
        let segments = [
            segment("s1", 0, 1000),
            segment("s2", 3000, 4000),
        ]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: segments, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "s1", startMs: 1300, endMs: 1700, text: "hi")])
    }

    @Test func micSegmentsSplitTheMicBetweenTheUserAndSomeoneBesideThem() {
        let you = TrackWords(role: "you", words: [
            .at("hi", 0, 500),
            .at("hello", 5000, 5500),
        ])
        let micSegments = [
            segment("you", 0, 1000),
            segment("r1", 4500, 6000),
        ]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you], segments: nil, micSegments: micSegments, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [
            Meeting.Paragraph(speaker: "you", startMs: 0, endMs: 500, text: "hi"),
            Meeting.Paragraph(speaker: "r1", startMs: 5000, endMs: 5500, text: "hello"),
        ])
    }

    @Test func aDictationIsDroppedEvenInsideSomeoneElsesSegment() {
        let you = TrackWords(role: "you", words: [
            .at("hi", 0, 500),
        ])
        let micSegments = [segment("r1", 0, 1000)]
        let paragraphs = TranscriptMerge.paragraphs(
            tracks: [you], segments: nil, micSegments: micSegments, dictations: [Meeting.Span(startMs: 0, endMs: 1000)], gap: .seconds(2))
        #expect(paragraphs.isEmpty)
    }

    @Test func aWordBeforeTheFirstSegmentTakesIt() {
        let them = TrackWords(role: "them", words: [
            .at("hi", 1400, 1800),
        ])
        let segments = [segment("s1", 2000, 3000)]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: segments, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "s1", startMs: 1400, endMs: 1800, text: "hi")])
    }

    @Test func overlappingSegmentsTheNearerCentreWins() {
        let them = TrackWords(role: "them", words: [
            .at("hi", 1100, 1300),
        ])
        let segments = [
            segment("s1", 0, 2000),
            segment("s2", 1000, 3000),
        ]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: segments, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "s1", startMs: 1100, endMs: 1300, text: "hi")])
    }

    @Test func aWordFarFromEverySegmentTakesThePreviousWordsSpeaker() {
        let them = TrackWords(role: "them", words: [
            .at("hi", 100, 300),
            .at("there", 10_000, 10_300),
        ])
        let segments = [segment("s1", 0, 1000)]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: segments, dictations: [], gap: .seconds(20))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "s1", startMs: 100, endMs: 10_300, text: "hi there")])
    }
}
