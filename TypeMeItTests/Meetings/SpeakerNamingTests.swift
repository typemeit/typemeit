import Testing
@testable import TypeMeIt

struct SpeakerNamingTests {
    private static let you = Meeting.Speaker(id: Meeting.Speaker.you, name: "You", isYou: true, talkMs: 0)

    /// A diarized speaker no one has named yet, `sN` called "Speaker N".
    private func numbered(_ n: Int, talkMs: Int) -> Meeting.Speaker {
        Meeting.Speaker(id: "s\(n)", name: Meeting.Speaker.numberedName(n), isYou: false, talkMs: talkMs)
    }

    /// `SpeakerNaming.align` with the thresholds the transcriber passes it.
    private func align(
        speakers: [Meeting.Speaker], segments: [SpeakerSegment] = [], paragraphs: [Meeting.Paragraph] = [],
        names: MeetingNames, talkers: [String] = [], userName: String? = nil, lagMs: Int = 0
    ) -> (speakers: [Meeting.Speaker], paragraphs: [Meeting.Paragraph]) {
        SpeakerNaming.align(
            speakers: speakers, segments: segments, paragraphs: paragraphs, names: names, talkers: talkers,
            userName: userName, lagMs: lagMs, captionMatch: Fixed.meetingCaptionMatch,
            minOverlapMs: Fixed.meetingNameMinOverlapSeconds * 1000, margin: Fixed.meetingNameMargin)
    }

    @Test func threeDiarizedSpeakersAgainstThreeNamesSpansWith400msLag() {
        let speakers = [
            Self.you,
            numbered(1, talkMs: 30_000),
            numbered(2, talkMs: 30_000),
            numbered(3, talkMs: 30_000),
        ]
        let segments = [
            segment("s1", 0, 30_000),
            segment("s2", 30_000, 60_000),
            segment("s3", 60_000, 90_000),
        ]
        // Each span was recorded 400 ms after the voice that produced it.
        let names = MeetingNames(source: .speaking, roster: [], channel: nil, spans: [
            MeetingNames.Span(name: "Ana", startMs: 400, endMs: 30_400),
            MeetingNames.Span(name: "Ben", startMs: 30_400, endMs: 60_400),
            MeetingNames.Span(name: "Cy", startMs: 60_400, endMs: 90_400),
        ], captions: nil)

        let result = align(speakers: speakers, segments: segments, names: names, lagMs: 400)

        #expect(result.speakers == [
            Self.you,
            Meeting.Speaker(id: "s1", name: "Ana", isYou: false, talkMs: 30_000, nameSource: .speaking),
            Meeting.Speaker(id: "s2", name: "Ben", isYou: false, talkMs: 30_000, nameSource: .speaking),
            Meeting.Speaker(id: "s3", name: "Cy", isYou: false, talkMs: 30_000, nameSource: .speaking),
        ])
        #expect(result.paragraphs == [])
    }

    @Test func aSpeakerWhoNeverShowsAsSpeakingStaysANumber() {
        let speakers = [
            Self.you,
            numbered(1, talkMs: 30_000),
            numbered(2, talkMs: 30_000),
        ]
        let segments = [
            segment("s1", 0, 30_000),
            segment("s2", 30_000, 60_000),
        ]
        // Only s1 ever lights the speaking indicator.
        let names = MeetingNames(source: .speaking, roster: [], channel: nil, spans: [
            MeetingNames.Span(name: "Ana", startMs: 0, endMs: 30_000),
        ], captions: nil)

        let result = align(speakers: speakers, segments: segments, names: names)

        #expect(result.speakers == [
            Self.you,
            Meeting.Speaker(id: "s1", name: "Ana", isYou: false, talkMs: 30_000, nameSource: .speaking),
            numbered(2, talkMs: 30_000),
        ])
    }

    @Test func twoNamesOnOneSpeakerStayUnassigned() {
        let speakers = [
            Self.you,
            numbered(1, talkMs: 30_000),
        ]
        let segments = [segment("s1", 0, 30_000)]
        // Two people on one tile: both names only ever overlap the one
        // diarized speaker, and by nearly the same amount.
        let names = MeetingNames(source: .speaking, roster: [], channel: nil, spans: [
            MeetingNames.Span(name: "Ana", startMs: 0, endMs: 20_000),
            MeetingNames.Span(name: "Ben", startMs: 0, endMs: 19_000),
        ], captions: nil)

        let result = align(speakers: speakers, segments: segments, names: names)

        #expect(result.speakers == speakers)
    }

    @Test func captionsLeaveSomeoneBesideTheUserAlone() {
        // `r1` is added to the speakers after naming; its words came through the user's tile.
        let paragraphs = [Meeting.Paragraph(speaker: "r1", startMs: 0, endMs: 5_000, text: "hello everyone how are you")]
        let names = MeetingNames(source: .captions, roster: [], channel: nil, spans: [], captions: [
            MeetingNames.Caption(name: "Ana", startMs: 1_000, text: "hello everyone how are you"),
        ])

        let result = align(speakers: [Self.you], paragraphs: paragraphs, names: names)

        #expect(result.speakers == [Self.you])
        #expect(result.paragraphs == paragraphs)
    }

    @Test func captionsOverrideADiarizerThatMergedTwoPeople() {
        let speakers = [
            Self.you,
            numbered(1, talkMs: 10_000),
        ]
        let paragraphs = [
            Meeting.Paragraph(speaker: "s1", startMs: 0, endMs: 5_000, text: "hello everyone how are you"),
            Meeting.Paragraph(speaker: "s1", startMs: 10_000, endMs: 15_000, text: "thanks for joining today"),
        ]
        let names = MeetingNames(source: .captions, roster: [], channel: nil, spans: [], captions: [
            MeetingNames.Caption(name: "Ana", startMs: 1_000, text: "hello everyone how are you"),
            MeetingNames.Caption(name: "Ben", startMs: 12_000, text: "thanks for joining today"),
        ])

        let result = align(speakers: speakers, paragraphs: paragraphs, names: names)

        #expect(result.speakers == [
            Self.you,
            Meeting.Speaker(id: "c1", name: "Ana", isYou: false, talkMs: 0, nameSource: .captions),
            Meeting.Speaker(id: "c2", name: "Ben", isYou: false, talkMs: 0, nameSource: .captions),
        ])
        #expect(result.paragraphs == [
            Meeting.Paragraph(speaker: "c1", startMs: 0, endMs: 5_000, text: "hello everyone how are you"),
            Meeting.Paragraph(speaker: "c2", startMs: 10_000, endMs: 15_000, text: "thanks for joining today"),
        ])
    }

    @Test func theUsersNameIsNeverAssignedToTheFarEnd() {
        let speakers = [
            Self.you,
            numbered(1, talkMs: 25_000),
        ]
        let segments = [segment("s1", 0, 30_000)]
        // "Max" (the user) overlaps s1 more than "Ana" does, but must never
        // be assigned to the far end.
        let names = MeetingNames(source: .speaking, roster: [], channel: nil, spans: [
            MeetingNames.Span(name: "Max", startMs: 0, endMs: 30_000),
            MeetingNames.Span(name: "Ana", startMs: 0, endMs: 25_000),
        ], captions: nil)

        let result = align(speakers: speakers, segments: segments, names: names, userName: "Max")

        #expect(result.speakers == [
            Self.you,
            Meeting.Speaker(id: "s1", name: "Ana", isYou: false, talkMs: 25_000, nameSource: .speaking),
        ])
    }

    @Test func aUserRenameSurvivesRealignment() {
        let speakers = [
            Self.you,
            Meeting.Speaker(id: "s1", name: "Bob", isYou: false, talkMs: 100_000, nameSource: .user),
        ]
        let segments = [segment("s1", 0, 30_000)]
        let names = MeetingNames(source: .speaking, roster: [], channel: nil, spans: [
            MeetingNames.Span(name: "Ana", startMs: 0, endMs: 30_000),
        ], captions: nil)
        let paragraphs = [Meeting.Paragraph(speaker: "s1", startMs: 0, endMs: 30_000, text: "hi")]

        let result = align(speakers: speakers, segments: segments, paragraphs: paragraphs, names: names)

        #expect(result.speakers == speakers)
        #expect(result.paragraphs == paragraphs)
    }

    @Test func marginRejectsANearTie() {
        let speakers = [
            Self.you,
            numbered(1, talkMs: 30_000),
            numbered(2, talkMs: 30_000),
        ]
        let segments = [
            segment("s1", 0, 30_000),
            segment("s2", 40_000, 70_000),
        ]
        // s1's best name (Ana, 25 s) beats its second best (Ben, 20 s) by
        // less than the 1.5x margin, so s1 stays a number even though Ana
        // alone would clear the 20 s minimum. s2's win over Ben is clear.
        let names = MeetingNames(source: .speaking, roster: [], channel: nil, spans: [
            MeetingNames.Span(name: "Ana", startMs: 0, endMs: 25_000),
            MeetingNames.Span(name: "Ben", startMs: 0, endMs: 20_000),
            MeetingNames.Span(name: "Ben", startMs: 40_000, endMs: 70_000),
        ], captions: nil)

        let result = align(speakers: speakers, segments: segments, names: names)

        #expect(result.speakers == [
            Self.you,
            numbered(1, talkMs: 30_000),
            Meeting.Speaker(id: "s2", name: "Ben", isYou: false, talkMs: 30_000, nameSource: .speaking),
        ])
    }

    @Test func theOneToOneRosterCase() {
        let speakers = [
            Self.you,
            numbered(1, talkMs: 30_000),
        ]
        let names = MeetingNames(source: .roster, roster: ["Ana"], channel: nil, spans: [], captions: nil)

        let result = align(speakers: speakers, names: names)

        #expect(result.speakers == [
            Self.you,
            Meeting.Speaker(id: "s1", name: "Ana", isYou: false, talkMs: 30_000, nameSource: .roster),
        ])
    }

    @Test func aOneVoiceFarEndTakesTheOneNameShownTalking() {
        let them = Meeting.Speaker(id: Meeting.Speaker.them, name: "Them", isYou: false, talkMs: 30_000)
        // The diarizer left one voice, so there are no segments to overlap.
        let names = MeetingNames(source: .speaking, roster: ["Ana", "Ben"], channel: nil, spans: [
            MeetingNames.Span(name: "Ana", startMs: 0, endMs: 30_000),
        ], captions: nil)

        let result = align(speakers: [Self.you, them], names: names, talkers: ["Ana"])

        #expect(result.speakers == [
            Self.you,
            Meeting.Speaker(id: Meeting.Speaker.them, name: "Ana", isYou: false, talkMs: 30_000, nameSource: .speaking),
        ])
    }

    @Test func aOneVoiceFarEndWithTwoPeopleShownTalkingStaysThem() {
        let them = Meeting.Speaker(id: Meeting.Speaker.them, name: "Them", isYou: false, talkMs: 60_000)
        let names = MeetingNames(source: .speaking, roster: ["Ana", "Ben"], channel: nil, spans: [
            MeetingNames.Span(name: "Ana", startMs: 0, endMs: 30_000),
            MeetingNames.Span(name: "Ben", startMs: 30_000, endMs: 60_000),
        ], captions: nil)

        let result = align(speakers: [Self.you, them], names: names, talkers: ["Ana", "Ben"])

        #expect(result.speakers == [Self.you, them])
    }

    @Test func lagShiftsASpanAcrossTheMinimumOverlapBoundary() {
        let speakers = [
            Self.you,
            numbered(1, talkMs: 20_000),
        ]
        let segments = [segment("s1", 0, 20_000)]
        // Recorded 500 ms late: raw overlap with the segment is 19,500 ms,
        // just under the 20,000 ms minimum. Shifting the span 500 ms
        // earlier lines it up exactly with the segment, crossing the
        // minimum-overlap boundary.
        let names = MeetingNames(source: .speaking, roster: [], channel: nil, spans: [
            MeetingNames.Span(name: "Ana", startMs: 500, endMs: 20_500),
        ], captions: nil)

        let result = align(speakers: speakers, segments: segments, names: names, lagMs: 500)

        #expect(result.speakers == [
            Self.you,
            Meeting.Speaker(id: "s1", name: "Ana", isYou: false, talkMs: 20_000, nameSource: .speaking),
        ])
    }

    @Test func theTitleIsTheChannelAndTheOthersFirstNames() {
        let names = MeetingNames(source: .roster, roster: ["Max Mitchell", "Ana Lopez", "Ben Ode", "Cy Two", "Di Three"], channel: "design", spans: [], captions: nil)
        #expect(names.title(excluding: "Max Mitchell") == "#design, Ana, Ben +2")
    }

    @Test func aOneToOneTitleIsTheOtherName() {
        let names = MeetingNames(source: .roster, roster: ["Max Mitchell", "Ana Lopez"], channel: nil, spans: [], captions: nil)
        #expect(names.title(excluding: "Max Mitchell") == "Ana")
    }

    @Test func noOtherNameIsNoTitle() {
        let names = MeetingNames(source: .roster, roster: ["Max Mitchell"], channel: nil, spans: [], captions: nil)
        #expect(names.title(excluding: "Max Mitchell") == nil)
    }
}
