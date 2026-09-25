import Testing
@testable import TypeMeIt

struct TranscriptMergeTests {
    @Test func interleavingTwoTracksInTimeOrder() {
        let you = TrackWords(role: "you", words: [
            Transcriber.Word(text: "hi", confidence: 1, start: .milliseconds(0), end: .milliseconds(500)),
        ])
        let them = TrackWords(role: "them", words: [
            Transcriber.Word(text: "hey", confidence: 1, start: .milliseconds(200), end: .milliseconds(700)),
        ])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [
            Meeting.Paragraph(speaker: "you", startMs: 0, endMs: 500, text: "hi"),
            Meeting.Paragraph(speaker: "them", startMs: 200, endMs: 700, text: "hey"),
        ])
    }

    @Test func twoPeopleTalkingAtOnceStayTwoParagraphs() {
        let you = TrackWords(role: "you", words: (0..<4).map {
            Transcriber.Word(text: "a\($0)", confidence: 1, start: .milliseconds($0 * 400), end: .milliseconds($0 * 400 + 300))
        })
        let them = TrackWords(role: "them", words: (0..<4).map {
            Transcriber.Word(text: "b\($0)", confidence: 1, start: .milliseconds($0 * 400 + 100), end: .milliseconds($0 * 400 + 350))
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
            Transcriber.Word(text: "\(prefix)\(i)", confidence: 1, start: .milliseconds(ms), end: .milliseconds(ms + 300))
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
        let you = TrackWords(role: "you", words: [Transcriber.Word(text: "Um,", confidence: 1, start: .milliseconds(3100), end: .milliseconds(3300))])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs.map(\.speaker) == ["them"])
        #expect(paragraphs[0].endMs == 5900)
    }

    @Test func dictationRemovesAMicWord() {
        let you = TrackWords(role: "you", words: [
            Transcriber.Word(text: "hello", confidence: 1, start: .milliseconds(0), end: .milliseconds(500)),
        ])
        let paragraphs = TranscriptMerge.paragraphs(
            tracks: [you], segments: nil,
            dictations: [Meeting.Span(startMs: 0, endMs: 1000)], gap: .seconds(2)
        )
        #expect(paragraphs == [])
    }

    @Test func gapSplitsAParagraph() {
        let you = TrackWords(role: "you", words: [
            Transcriber.Word(text: "a", confidence: 1, start: .milliseconds(0), end: .milliseconds(500)),
            Transcriber.Word(text: "b", confidence: 1, start: .milliseconds(3000), end: .milliseconds(3500)),
        ])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you], segments: nil, dictations: [], gap: .seconds(1))
        #expect(paragraphs == [
            Meeting.Paragraph(speaker: "you", startMs: 0, endMs: 500, text: "a"),
            Meeting.Paragraph(speaker: "you", startMs: 3000, endMs: 3500, text: "b"),
        ])
    }

    @Test func anEmptyTrackContributesNothing() {
        let you = TrackWords(role: "you", words: [])
        let them = TrackWords(role: "them", words: [
            Transcriber.Word(text: "hi", confidence: 1, start: .milliseconds(0), end: .milliseconds(500)),
        ])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "them", startMs: 0, endMs: 500, text: "hi")])
    }

    @Test func aWordBetweenTwoSegmentsTakesTheNearestWithinOneSecond() {
        let them = TrackWords(role: "them", words: [
            Transcriber.Word(text: "hi", confidence: 1, start: .milliseconds(1300), end: .milliseconds(1700)),
        ])
        let segments = [
            SpeakerSegment(speaker: "s1", startMs: 0, endMs: 1000),
            SpeakerSegment(speaker: "s2", startMs: 3000, endMs: 4000),
        ]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: segments, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "s1", startMs: 1300, endMs: 1700, text: "hi")])
    }

    @Test func aWordBeforeTheFirstSegmentTakesIt() {
        let them = TrackWords(role: "them", words: [
            Transcriber.Word(text: "hi", confidence: 1, start: .milliseconds(1400), end: .milliseconds(1800)),
        ])
        let segments = [SpeakerSegment(speaker: "s1", startMs: 2000, endMs: 3000)]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: segments, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "s1", startMs: 1400, endMs: 1800, text: "hi")])
    }

    @Test func overlappingSegmentsTheNearerCentreWins() {
        let them = TrackWords(role: "them", words: [
            Transcriber.Word(text: "hi", confidence: 1, start: .milliseconds(1100), end: .milliseconds(1300)),
        ])
        let segments = [
            SpeakerSegment(speaker: "s1", startMs: 0, endMs: 2000),
            SpeakerSegment(speaker: "s2", startMs: 1000, endMs: 3000),
        ]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: segments, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "s1", startMs: 1100, endMs: 1300, text: "hi")])
    }

    @Test func aWordFarFromEverySegmentTakesThePreviousWordsSpeaker() {
        let them = TrackWords(role: "them", words: [
            Transcriber.Word(text: "hi", confidence: 1, start: .milliseconds(100), end: .milliseconds(300)),
            Transcriber.Word(text: "there", confidence: 1, start: .milliseconds(10_000), end: .milliseconds(10_300)),
        ])
        let segments = [SpeakerSegment(speaker: "s1", startMs: 0, endMs: 1000)]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: segments, dictations: [], gap: .seconds(20))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "s1", startMs: 100, endMs: 10_300, text: "hi there")])
    }
}
