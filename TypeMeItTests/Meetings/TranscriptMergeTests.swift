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
        #expect(paragraphs[1].aside == nil)
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

    @Test func aWordTakesTheSpeakerCoveringMostOfIt() {
        // The midpoint, 1500, is in s2's segment; s1's covers more of the word.
        let them = TrackWords(role: "them", words: [
            .at("exactly", 1000, 2000),
        ])
        let segments = [
            segment("s1", 900, 1400),
            segment("s2", 1400, 1600),
        ]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: segments, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "s1", startMs: 1000, endMs: 2000, text: "exactly")])
    }

    @Test func aShortReplyInsideATurnIsAnAsideWhereItWasSaid() {
        // The rest of the turn after the reply lasts 1.1 s, too short to cut
        // at another speaker's turn; an aside cuts it anyway.
        let them = TrackWords(role: "them", words: run("b", fromMs: 0, toMs: 4400))
        let you = TrackWords(role: "you", words: [.at("Exactly.", 3100, 3600)])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [
            Meeting.Paragraph(speaker: "them", startMs: 0, endMs: 3100, text: "b0 b1 b2 b3 b4 b5 b6 b7"),
            Meeting.Paragraph(speaker: "you", startMs: 3100, endMs: 3600, text: "Exactly.", aside: true),
            Meeting.Paragraph(speaker: "them", startMs: 3200, endMs: 4300, text: "b8 b9 b10"),
        ])
    }

    @Test func aFragmentInsideATurnIsNotAnAside() {
        let them = TrackWords(role: "them", words: run("b", fromMs: 0, toMs: 4400))
        let you = TrackWords(role: "you", words: [.at("and", 3100, 3300), .at("then", 3300, 3600)])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs.map(\.speaker) == ["them", "you"])
        #expect(paragraphs.allSatisfy { $0.aside == nil })
    }

    @Test func aReplyTwoSecondsLongIsNotAnAside() {
        let them = TrackWords(role: "them", words: run("b", fromMs: 0, toMs: 8000))
        let you = TrackWords(role: "you", words: run("a", fromMs: 3100, toMs: 5600))
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs.map(\.speaker) == ["them", "you", "them"])
        #expect(paragraphs.allSatisfy { $0.aside == nil })
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

    @Test func aReplyOverTheEndOfAQuestionLeavesTheQuestionWhole() {
        let them = TrackWords(role: "them", words: [
            .at("Do", 0, 300), .at("we", 400, 700), .at("need", 800, 1100), .at("it", 1200, 1500),
            .at("so", 1600, 1900), .at("for", 2100, 2400), .at("the", 2500, 2800), .at("whole", 2900, 3200), .at("team", 3300, 3600), .at("now?", 3700, 3900),
        ])
        let you = TrackWords(role: "you", words: run("a", fromMs: 2000, toMs: 9000))
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [
            Meeting.Paragraph(speaker: "them", startMs: 0, endMs: 3900, text: "Do we need it so for the whole team now?"),
            Meeting.Paragraph(speaker: "you", startMs: 2000, endMs: 9100, text: run("a", fromMs: 2000, toMs: 9000).map(\.text).joined(separator: " ")),
        ])
    }

    @Test func someoneWhoSpeaksUpMidSentenceCutsItWhereTheySpoke() {
        // The sentence runs on 3 s past the interruption: too far to wait for its end.
        let them = TrackWords(role: "them", words: run("b", fromMs: 0, toMs: 5000) + [.at("done.", 5000, 5300)])
        let you = TrackWords(role: "you", words: run("a", fromMs: 2100, toMs: 4400))
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs.map(\.speaker) == ["them", "you", "them"])
        #expect(paragraphs.map(\.startMs) == [0, 2100, 2400])
    }

    @Test func aShortSentenceEndingATurnUnderTheReplyIsAnAside() {
        let them = TrackWords(role: "them", words: [
            .at("Do", 0, 300), .at("we", 400, 700), .at("need", 800, 1100), .at("it", 1200, 1500),
            .at("for", 2100, 2400), .at("cost?", 2500, 2900), .at("Okay,", 3500, 3800), .at("cool.", 3900, 4200),
        ])
        let you = TrackWords(role: "you", words: [
            .at("No.", 2000, 2300), .at("Definitely", 2400, 2900), .at("not", 3000, 3300), .at("cost.", 3400, 3700),
            .at("It", 3800, 4100), .at("has", 4200, 4500), .at("a", 4600, 4900), .at("limit.", 5000, 5300),
        ])
        let paragraphs = TranscriptMerge.paragraphs(tracks: [you, them], segments: nil, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [
            Meeting.Paragraph(speaker: "them", startMs: 0, endMs: 2900, text: "Do we need it for cost?"),
            Meeting.Paragraph(speaker: "you", startMs: 2000, endMs: 3700, text: "No. Definitely not cost."),
            Meeting.Paragraph(speaker: "them", startMs: 3500, endMs: 4200, text: "Okay, cool.", aside: true),
            Meeting.Paragraph(speaker: "you", startMs: 3800, endMs: 5300, text: "It has a limit."),
        ])
    }

    @Test func aWordTheDiarizerHopsToAnotherVoiceMidSentenceStaysWithTheSentence() {
        let them = TrackWords(role: "them", words: [
            .at("And", 0, 300), .at("also", 400, 700), .at("consistency,", 800, 1300), .at("particularly", 1400, 1900),
            .at("as", 2000, 2200), .at("we", 2300, 2500), .at("talk.", 2600, 3000),
        ])
        let segments = [segment("s1", 0, 1350), segment("s2", 1350, 1950), segment("s1", 1950, 3000)]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: segments, dictations: [], gap: .seconds(2))
        #expect(paragraphs == [Meeting.Paragraph(speaker: "s1", startMs: 0, endMs: 3000, text: "And also consistency, particularly as we talk.")])
    }

    @Test func aReplyThatReadsAsASentenceKeepsItsVoice() {
        let them = TrackWords(role: "them", words: [
            .at("And", 0, 300), .at("also", 400, 700), .at("Yeah.", 1400, 1900), .at("as", 2000, 2200), .at("we", 2300, 2500), .at("talk.", 2600, 3000),
        ])
        let segments = [segment("s1", 0, 1350), segment("s2", 1350, 1950), segment("s1", 1950, 3000)]
        let paragraphs = TranscriptMerge.paragraphs(tracks: [them], segments: segments, dictations: [], gap: .seconds(2))
        #expect(paragraphs.map(\.speaker) == ["s1", "s2", "s1"])
    }
}
