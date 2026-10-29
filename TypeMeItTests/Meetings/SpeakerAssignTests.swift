import Foundation
import Testing
@testable import TypeMeIt

struct SpeakerAssignTests {
    private func speaker(_ id: String, _ name: String, you: Bool = false, ms: Int = 10_000, source: MeetingNames.Source? = nil) -> Meeting.Speaker {
        Meeting.Speaker(id: id, name: name, isYou: you, talkMs: ms, nameSource: source)
    }

    private func paragraph(_ speaker: String, _ start: Int, _ end: Int, _ text: String) -> Meeting.Paragraph {
        Meeting.Paragraph(speaker: speaker, startMs: start, endMs: end, text: text)
    }

    /// A call like 6 October's: the user and three people beside them, unnamed.
    private func call(roster: [String] = ["Max Mitchell", "Ada Rowe", "Alma Lund", "Nils Shaw"],
                      speakers: [Meeting.Speaker]? = nil, paragraphs: [Meeting.Paragraph] = []) -> Meeting {
        var m = MeetingFixtures.example
        m.speakers = speakers ?? [speaker("you", "You", you: true), speaker("r1", "Speaker 2"), speaker("r2", "Speaker 3"), speaker("r3", "Speaker 4")]
        m.paragraphs = paragraphs
        m.names = MeetingNames(source: .speaking, roster: roster, channel: nil, spans: [], captions: nil, user: "Max Mitchell")
        return m
    }

    // MARK: Predicted

    @Test func renamingKeepsTheNameTheCallGaveAsThePrediction() {
        let m = call(speakers: [speaker("you", "You", you: true), speaker("s1", "Theo Brandt", source: .speaking)])
        let renamed = SpeakerAssign.apply(.name("Ines Varga"), to: "s1", in: m)
        let again = SpeakerAssign.apply(.name("Ines Varga-Lowe"), to: "s1", in: renamed)
        #expect(again.speakers[1] == Meeting.Speaker(id: "s1", name: "Ines Varga-Lowe", isYou: false, talkMs: 10_000, nameSource: .user,
                                                    predicted: Meeting.Speaker.Prediction(name: "Theo Brandt", source: .speaking)))
    }

    @Test func aNumberedSpeakerRenamedHasNoPrediction() {
        let m = SpeakerAssign.apply(.name("Ines Varga"), to: "r1", in: call())
        #expect(m.speakers[1].predicted == nil)
    }

    // MARK: Unknown

    @Test func aNumberedSpeakerIsUnknownAndYouAndTheRoomAreNot() {
        #expect(SpeakerAssign.isUnknown(speaker("r1", "Speaker 2")))
        #expect(SpeakerAssign.isUnknown(speaker("them", "Them")))
        #expect(!SpeakerAssign.isUnknown(speaker("you", "You", you: true)))
        #expect(!SpeakerAssign.isUnknown(speaker("c1", "Colm Fry", source: .speaking)))
        #expect(!SpeakerAssign.isUnknown(speaker("room", "Room")))
    }

    @Test func aSharedMeetingsNumberedLabelsAreUnknown() {
        #expect(SpeakerAssign.isUnknown(speaker("s2", "Speaker 1", source: .user)))
        #expect(SpeakerAssign.isUnknown(speaker("s3", "Them", source: .user)))
        #expect(!SpeakerAssign.isUnknown(speaker("s4", "Speaker One", source: .user)))
        #expect(!SpeakerAssign.isUnknown(speaker("s5", "Speaker 2b", source: .user)))
    }

    @Test func theNextUnknownWrapsAndStartsOverAfterAMerge() {
        let m = call()
        #expect(SpeakerAssign.nextUnknown(after: nil, in: m) == "r1")
        #expect(SpeakerAssign.nextUnknown(after: "r3", in: m) == "r1")
        #expect(SpeakerAssign.nextUnknown(after: "r1", in: m, backwards: true) == "r3")
        #expect(SpeakerAssign.nextUnknown(after: "gone", in: m) == "r1")
    }

    @Test func theWhoFilterCallsEveryUnknownSpeakerUnknown() {
        let m = call(speakers: [speaker("you", "You", you: true), speaker("r1", "Speaker 2"), speaker("r2", "Speaker 3"), speaker("c1", "Colm Fry", source: .speaking)])
        #expect(MeetingsTab.others(in: m) == ["unknown", "unknown", "Colm Fry"])
    }

    // MARK: First names

    @Test func theTranscriptShowsFirstNamesAndInitialsOnlyWhereTwoShareOne() {
        var m = MeetingFixtures.example
        m.speakers = [
            speaker("you", "You", you: true), speaker("s2", "Speaker 2"),
            speaker("c1", "Colm Fry", source: .roster), speaker("a1", "Ana Lopez", source: .roster),
            speaker("a2", "ana Reyes", source: .roster), speaker("a3", "Ana Ruiz", source: .roster),
            speaker("a4", "Ana", source: .roster), speaker("b1", "Ben Ortiz", source: .user),
        ]
        #expect(m.speakers.map { SpeakerAssign.firstName(of: $0.id, in: m) } == ["You", "Speaker 2", "Colm", "Ana L.", "ana Reyes", "Ana Ruiz", "Ana", "Ben"])
        #expect(SpeakerAssign.firstName(of: "gone", in: m) == "gone")
    }

    // MARK: The user

    @Test func aGoogleNameThatShortensTheMacsIsTheUser() {
        #expect(SpeakerAssign.isUser("Max Mitchell", userName: "Maximilian Mitchell"))
        #expect(SpeakerAssign.isUser("max mitchell", userName: "Max Mitchell"))
        #expect(!SpeakerAssign.isUser("Maxine Smith", userName: "Max Mitchell"))
        #expect(!SpeakerAssign.isUser("Max", userName: "Maximilian Mitchell"))
    }

    @Test func theCallsNamesLeaveTheUserOut() {
        #expect(SpeakerAssign.callNames(call()) == ["Ada Rowe", "Alma Lund", "Nils Shaw"])
    }

    // MARK: Clips

    @Test func clipsAreSoloStretchesSpreadAcrossTheMeeting() {
        let eight = "one two three four five six seven eight"
        let m = call(paragraphs: [
            paragraph("r1", 10_000, 15_000, eight),
            paragraph("r2", 15_200, 18_000, "someone else talks over the end here"),
            paragraph("r1", 30_000, 35_000, eight + " nine"),
            paragraph("r1", 200_000, 205_000, eight),
            paragraph("r1", 400_000, 401_000, "too short"),
        ])
        let clips = SpeakerAssign.clips(for: "r1", in: m)
        #expect(clips.map(\.startMs) == [29_750, 199_750])
        #expect(clips.first?.endMs == 35_250)
    }

    @Test func aLongParagraphPlaysItsStartAndEndsInAnEllipsis() {
        let words = (1...40).map { "w\($0)" }.joined(separator: " ")
        let m = call(paragraphs: [paragraph("r1", 10_000, 30_000, words)])
        let clip = SpeakerAssign.clips(for: "r1", in: m).first
        #expect(clip == SpeakerAssign.Clip(startMs: 9_750, endMs: 18_250, text: (1...16).map { "w\($0)" }.joined(separator: " ") + "…"))
    }

    @Test func aSpeakerWithNoGoodStretchStillOffersItsLongest() {
        let m = call(paragraphs: [
            paragraph("r3", 10_000, 11_000, "yeah"),
            paragraph("r3", 20_000, 22_000, "and like that"),
        ])
        #expect(SpeakerAssign.clips(for: "r3", in: m).map(\.text) == ["yeah", "and like that"])
    }

    // MARK: Names offered

    @Test func emptyTheFieldNumbersTheCallsNamesThenPastPeopleAndTheUser() {
        let past = [SpeakerAssign.Person(name: "Edie O'Neill", calls: 6), SpeakerAssign.Person(name: "Cora Jensen", calls: 2)]
        let options = SpeakerAssign.options(for: "r2", in: call(), query: "", past: past)
        #expect(options.map(\.label) == ["Ada Rowe", "Alma Lund", "Nils Shaw", "Edie O'Neill", "Cora Jensen", "that's me"])
        #expect(options.map(\.key) == [1, 2, 3, nil, nil, nil])
        #expect(options[3].detail == "6 calls")
        #expect(options[5].detail == "merge into You")
    }

    @Test func theVoiceMatchComesFirstAndTheCallsNamesKeepTheirKeys() {
        let options = SpeakerAssign.options(for: "r2", in: call(), query: "", past: [], voice: "Nils Shaw")
        #expect(options.map(\.label) == ["Nils Shaw", "Ada Rowe", "Alma Lund", "that's me"])
        #expect(options.map(\.group) == [.voice, .call, .call, .other])
        #expect(options.map(\.key) == [nil, 1, 2, nil])
        #expect(SpeakerAssign.options(for: "r2", in: call(), query: "al", past: [], voice: "Nils Shaw").map(\.label) == ["Alma Lund", "use “al”"])
    }

    @Test func aNameAlreadyGivenIsOfferedAsAMerge() {
        let m = SpeakerAssign.apply(.name("Alma Lund"), to: "r1", in: call())
        let options = SpeakerAssign.options(for: "r2", in: m, query: "al", past: [])
        #expect(options.map(\.label) == ["Alma Lund", "use “al”"])
        #expect(options.map(\.group) == [.same, .other])
    }

    @Test func thatsMeMakesAVoiceYouWhenNoneIs() {
        let renamed = SpeakerAssign.apply(.name("Ada Rowe"), to: "you", in: call())
        #expect(SpeakerAssign.options(for: "r1", in: renamed, query: "me", past: []).map(\.label) == ["that's me"])
        let me = SpeakerAssign.apply(.me, to: "r1", in: renamed)
        #expect(me.speakers[1].isYou)
        #expect(me.speakers[1].name == "You")
    }

    @Test func aSpeakersOwnNameIsNotOffered() {
        let named = SpeakerAssign.apply(.name("Nils Shaw"), to: "r3", in: call())
        #expect(SpeakerAssign.options(for: "r3", in: named, query: "", past: []).map(\.label) == ["Ada Rowe", "Alma Lund", "that's me"])
    }

    @Test func typingOffersWhatWasTypedLast() {
        let options = SpeakerAssign.options(for: "r2", in: call(), query: "Hugh", past: [])
        #expect(options.map(\.label) == ["use “Hugh”"])
        #expect(options.first?.choice == .name("Hugh"))
    }

    @Test func pastPeopleWhoShareCallsWithThisListComeFirst() {
        var edie = call(roster: ["Edie O'Neill", "Ada Rowe"], speakers: [speaker("c1", "Edie O'Neill", source: .speaking)])
        edie.id = UUID()
        var ted = call(roster: ["Ted Nash"], speakers: [speaker("c1", "Ted Nash", source: .speaking)])
        ted.id = UUID()
        var tedAgain = ted
        tedAgain.id = UUID()
        var you = call(roster: [], speakers: [speaker("c1", "Maximilian Mitchell", source: .user), speaker("s2", "Speaker 1", source: .user)])
        you.id = UUID()
        let here = call()
        #expect(SpeakerAssign.past([here, edie, ted, tedAgain, you], for: here)
            == [SpeakerAssign.Person(name: "Edie O'Neill", calls: 1), SpeakerAssign.Person(name: "Ted Nash", calls: 2)])
    }

    // MARK: Choosing

    @Test func aNameIsTheUsers() {
        let m = SpeakerAssign.apply(.name("Ada Rowe"), to: "r1", in: call())
        #expect(m.speakers[1].name == "Ada Rowe")
        #expect(m.speakers[1].nameSource == .user)
    }

    @Test func theSameNameTwiceMergesTheTwo() {
        let start = call(paragraphs: [paragraph("r1", 0, 1_000, "a"), paragraph("r2", 1_000, 2_000, "b")])
        let named = SpeakerAssign.apply(.name("Alma Lund"), to: "r1", in: start)
        let merged = SpeakerAssign.apply(.name("alma lund"), to: "r2", in: named)
        #expect(merged.speakers.map(\.id) == ["you", "r1", "r3"])
        #expect(merged.speakers[1].talkMs == 20_000)
        #expect(merged.paragraphs.map(\.speaker) == ["r1", "r1"])
    }

    @Test func aMergeSplitsBackAsItWas() {
        let start = call(paragraphs: [paragraph("r1", 0, 1_000, "a"), paragraph("r2", 1_000, 4_000, "b"), paragraph("r2", 5_000, 6_000, "c")])
        let named = SpeakerAssign.apply(.name("Alma Lund"), to: "r1", in: start)
        let merged = SpeakerAssign.apply(.name("Alma Lund"), to: "r2", in: named)
        #expect(merged.mergedSpeakers?.map(\.name) == ["Speaker 3"])
        #expect(merged.paragraphs.map(\.mergedFrom) == [nil, "r2", "r2"])
        let options = SpeakerAssign.options(for: "r1", in: merged, query: "", past: [])
        #expect(options.last == SpeakerAssign.Option(choice: .split("r2"), label: "Speaker 3", group: .merged, detail: "split"))
        let split = SpeakerAssign.apply(.split("r2"), to: "r1", in: merged)
        #expect(split.speakers.map(\.id) == ["you", "r1", "r3", "r2"])
        #expect(split.speakers.map(\.talkMs) == [10_000, 16_000, 10_000, 4_000])
        #expect(split.paragraphs.map(\.speaker) == ["r1", "r2", "r2"])
        #expect(split.paragraphs.allSatisfy { $0.mergedFrom == nil })
        #expect(split.mergedSpeakers == nil)
    }

    @Test func aVoiceMergedTwiceSplitsFromWhereverItsLinesAre() {
        let start = call(paragraphs: [paragraph("r1", 0, 1_000, "a"), paragraph("r2", 1_000, 2_000, "b"), paragraph("r3", 2_000, 3_000, "c")])
        let b = SpeakerAssign.merge("r1", into: "r2", in: start)
        let c = SpeakerAssign.merge("r2", into: "r3", in: b)
        #expect(SpeakerAssign.mergedInto("r3", in: c).map(\.id) == ["r1", "r2"])
        let back = SpeakerAssign.split("r2", in: c)
        #expect(back.paragraphs.map(\.speaker) == ["r3", "r2", "r3"])
        #expect(SpeakerAssign.mergedInto("r3", in: back).map(\.id) == ["r1"])
    }

    @Test func thatsMeMergesIntoYou() {
        let m = SpeakerAssign.apply(.me, to: "r3", in: call(paragraphs: [paragraph("r3", 0, 1_000, "a")]))
        #expect(m.speakers.map(\.id) == ["you", "r1", "r2"])
        #expect(m.paragraphs.map(\.speaker) == ["you"])
    }

    @Test func renamingYouMakesThatVoiceSomeoneElse() {
        let m = SpeakerAssign.apply(.name("Ada Rowe"), to: "you", in: call())
        #expect(m.speakers[0].name == "Ada Rowe")
        #expect(!m.speakers[0].isYou)
    }

    @Test func theLastNameGoesToTheLastVoice() {
        let one = SpeakerAssign.apply(.name("Alma Lund"), to: "r1", in: call())
        #expect(SpeakerAssign.unknown(in: one).count == 2)
        let two = SpeakerAssign.apply(.name("Ada Rowe"), to: "r2", in: one)
        #expect(two.speakers[3].name == "Nils Shaw")
        #expect(two.speakers[3].nameSource == .roster)
        #expect(SpeakerAssign.unknown(in: two).isEmpty)
    }
}
