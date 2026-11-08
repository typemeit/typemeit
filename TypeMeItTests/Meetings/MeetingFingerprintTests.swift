import Testing
@testable import TypeMeIt

/// Invented meetings only: an hour long unless a test says otherwise, so a
/// cell of the 60 × 60 square is one second.
struct MeetingFingerprintTests {
    private static let hourMs = 3_600_000

    @Test func theSpeakerWithMostMillisecondsTakesTheCell() throws {
        let square = try fingerprint([paragraph("s1", 0, 600), paragraph("s2", 600, 1_000)])
        #expect(square.speaker(ofCell: 0) == "s1")
    }

    @Test func aTieGoesToWhoeverStartedFirst() throws {
        let square = try fingerprint([paragraph("s2", 0, 500), paragraph("s1", 500, 1_000)])
        #expect(square.speaker(ofCell: 0) == "s2")
    }

    @Test func speechUnderThirtyPercentOfACellIsQuiet() throws {
        let square = try fingerprint([paragraph("s1", 0, 290), paragraph("s1", 1_000, 1_300)])
        #expect(square.tone(ofCell: 0) == .quiet)
        #expect(square.speaker(ofCell: 1) == "s1")
    }

    @Test func anAsideOfHalfASecondWinsEvenAsTheMinority() throws {
        let square = try fingerprint([
            paragraph("s1", 10_000, 10_700), paragraph("s2", 10_700, 11_300, aside: true), paragraph("s1", 11_300, 12_000),
        ])
        #expect([10, 11].map(square.speaker(ofCell:)) == ["s2", "s2"])
    }

    @Test func aShorterAsideLosesToTheTurnAroundIt() throws {
        let square = try fingerprint([
            paragraph("s1", 10_000, 10_600), paragraph("s2", 10_600, 11_000, aside: true), paragraph("s1", 11_000, 12_000),
        ])
        #expect(square.speaker(ofCell: 10) == "s1")
    }

    @Test func youComeFirstThenOthersByTalkTime() throws {
        let speakers = [speaker("s1", talkMs: 10), speaker("you", talkMs: 1, isYou: true), speaker("s2", talkMs: 50)]
        let square = try fingerprint(
            [paragraph("you", 0, 1_000), paragraph("s2", 1_000, 2_000), paragraph("s1", 2_000, 3_000)], speakers: speakers)
        #expect(square.speakers == ["you", "s2", "s1"])
        #expect([0, 1, 2, 3].map(square.tone(ofCell:)) == [.you, .hue(.coral), .hue(.sky), .quiet])
    }

    @Test func withoutYouTheMostTalkativeTakesTheFirstHue() throws {
        let speakers = [speaker("s1", talkMs: 10), speaker("s2", talkMs: 50)]
        let square = try fingerprint([paragraph("s1", 0, 1_000), paragraph("s2", 1_000, 2_000)], speakers: speakers)
        #expect([0, 1].map(square.tone(ofCell:)) == [.hue(.sky), .hue(.coral)])
    }

    @Test func aNamedPersonKeepsTheirHueInEveryMeeting() throws {
        let busy = try fingerprint([paragraph("s3", 0, 1_000)], speakers: [
            speaker("s1", talkMs: 90), speaker("s2", talkMs: 80), speaker("s3", talkMs: 10, name: "Robin"),
        ])
        let quiet = try fingerprint([paragraph("s1", 0, 1_000)], speakers: [speaker("s1", talkMs: 5, name: " robin ")])
        #expect(busy.tone(ofCell: 0) == .hue(MeetingFingerprint.hue(for: "Robin")))
        #expect(quiet.tone(ofCell: 0) == .hue(MeetingFingerprint.hue(for: "Robin")))
    }

    @Test func aHueBothNamesWantGoesToWhoTalkedMore() throws {
        let names = ["Robin", "Sam", "Alex", "Jo", "Kit", "Lee", "Max", "Ash", "Ren"]
        let louder = try #require(names.first)
        let quieter = try #require(names.dropFirst().first { MeetingFingerprint.hue(for: $0) == MeetingFingerprint.hue(for: louder) })
        let square = try fingerprint([paragraph("s1", 0, 1_000), paragraph("s2", 1_000, 2_000)], speakers: [
            speaker("s2", talkMs: 10, name: quieter), speaker("s1", talkMs: 90, name: louder),
        ])
        let hues = MeetingFingerprint.hues
        let next = hues[(try #require(hues.firstIndex(of: MeetingFingerprint.hue(for: louder))) + 1) % hues.count]
        #expect([0, 1].map(square.tone(ofCell:)) == [.hue(MeetingFingerprint.hue(for: louder)), .hue(next)])
    }

    @Test func theUnnamedTakeTheHuesTheNamedLeave() throws {
        let named = MeetingFingerprint.hue(for: "Robin")
        let square = try fingerprint([paragraph("s2", 0, 1_000)], speakers: [
            speaker("s1", talkMs: 10, name: "Robin"), speaker("s2", talkMs: 90),
        ])
        #expect(square.tone(ofCell: 0) == .hue(try #require(MeetingFingerprint.hues.first { $0 != named })))
    }

    @Test func everyoneBeyondTheHuesSharesOneColour() throws {
        let others = (0...MeetingFingerprint.hues.count).map { speaker("s\($0)", talkMs: 100 - $0) }
        let last = MeetingFingerprint.hues.count
        let square = try fingerprint([paragraph("s\(last)", 0, 1_000)], speakers: others)
        #expect(square.tone(ofCell: 0) == .rest)
    }

    @Test func aSpeakerMissingFromTheListComesLast() throws {
        let square = try fingerprint([paragraph("s9", 0, 1_000)], speakers: [speaker("you", talkMs: 0, isYou: true)])
        #expect(square.speakers == ["you", "s9"])
    }

    @Test func aShortMeetingStillFillsTheSquare() throws {
        let square = try fingerprint([paragraph("you", 0, 30_000)], durationMs: 30_000)
        #expect(square.cells.count == MeetingFingerprint.side * MeetingFingerprint.side)
        #expect(square.cells.allSatisfy { $0 == 0 })
    }

    @Test func aLongMeetingSpreadsItsCellsOverMoreTime() throws {
        let square = try fingerprint([paragraph("s1", 5_400_000 - 1_500, 5_400_000)], durationMs: 5_400_000)
        #expect(square.cellMs == 1_500)
        #expect(square.startMs(ofCell: 60) == 90_000)
        #expect(square.cell(atMs: 90_000) == 60)
        #expect(square.speaker(ofCell: square.cells.count - 1) == "s1")
    }

    @Test func aMeetingWithNoLengthHasNoFingerprint() {
        #expect(meeting([], durationMs: 0).fingerprint == nil)
    }

    @Test func renumberingAnUnnamedSpeakerChangesNothing() throws {
        let paragraphs = [paragraph("s1", 0, 1_000)]
        var renamed = Self.speakers
        renamed[1].name = Meeting.Speaker.numberedName(7)
        #expect(try fingerprint(paragraphs) == fingerprint(paragraphs, speakers: renamed))
    }

    @Test func foldingTakesTheValueMostOfABlockHolds() throws {
        let square = try fingerprint([
            paragraph("s1", 0, 3_000), paragraph("s1", 60_000, 63_000),
            paragraph("s2", 120_000, 124_000), paragraph("s2", 180_000, 184_000),
        ]).folded()
        #expect(square.side == MeetingFingerprint.side / MeetingFingerprint.fold)
        #expect(square.speaker(ofCell: 0) == "s2")
        #expect(square.tone(ofCell: 1) == .quiet)
    }

    @Test func aFoldTieGoesToTheFirstCellInReadingOrder() throws {
        let square = try fingerprint([
            paragraph("s2", 0, 4_000), paragraph("s2", 60_000, 64_000),
            paragraph("s1", 120_000, 124_000), paragraph("s1", 180_000, 184_000),
        ]).folded()
        #expect(square.speaker(ofCell: 0) == "s2")
    }

    @Test func sharesCountYouAndTheOthers() throws {
        let square = try fingerprint([paragraph("you", 0, 4_000), paragraph("s1", 4_000, 7_000), paragraph("s2", 7_000, 10_000)])
        #expect(square.spokenShares == "you 40%, 2 others 60%")
    }

    @Test func sharesForOnlyYou() throws {
        #expect(try fingerprint([paragraph("you", 0, 4_000)]).spokenShares == "you 100%")
    }

    @Test func sharesWithoutYouCountTheSpeakers() throws {
        let square = try fingerprint([paragraph("s1", 0, 1_000)], speakers: [speaker("s1", talkMs: 1)])
        #expect(square.spokenShares == "1 speaker")
    }

    @Test func aSilentMeetingReadsQuiet() throws {
        #expect(try fingerprint([]).spokenShares == "quiet")
    }

    // MARK: Fixtures

    private static let speakers = [
        speaker("you", talkMs: 300, isYou: true), speaker("s1", talkMs: 200), speaker("s2", talkMs: 100),
    ]

    /// Unnamed ("Speaker 2") unless given `name`.
    private static func speaker(_ id: String, talkMs: Int, isYou: Bool = false, name: String? = nil) -> Meeting.Speaker {
        Meeting.Speaker(id: id, name: name ?? (isYou ? "You" : Meeting.Speaker.numberedName(2)), isYou: isYou, talkMs: talkMs)
    }

    private func speaker(_ id: String, talkMs: Int, isYou: Bool = false, name: String? = nil) -> Meeting.Speaker {
        Self.speaker(id, talkMs: talkMs, isYou: isYou, name: name)
    }

    private func paragraph(_ speaker: String, _ startMs: Int, _ endMs: Int, aside: Bool? = nil) -> Meeting.Paragraph {
        Meeting.Paragraph(speaker: speaker, startMs: startMs, endMs: endMs, text: "", aside: aside)
    }

    private func meeting(_ paragraphs: [Meeting.Paragraph], durationMs: Int = Self.hourMs, speakers: [Meeting.Speaker] = Self.speakers) -> Meeting {
        MeetingFixtures.meeting(durationMs: durationMs, speakers: speakers, paragraphs: paragraphs)
    }

    private func fingerprint(_ paragraphs: [Meeting.Paragraph], durationMs: Int = Self.hourMs,
                             speakers: [Meeting.Speaker] = Self.speakers) throws -> MeetingFingerprint {
        try #require(meeting(paragraphs, durationMs: durationMs, speakers: speakers).fingerprint)
    }
}
