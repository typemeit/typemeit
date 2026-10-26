import Testing
@testable import TypeMeIt

struct RoomVoicesTests {
    @Test func aListedNameThatNeverLitIsSilent() {
        let names = MeetingNames(source: .speaking, roster: ["Edie O'Neill", "Hugh Ashby-Clarke", "Max Mitchell"], channel: nil, spans: [
            MeetingNames.Span(name: "Hugh Ashby-Clarke", startMs: 0, endMs: 5_000),
            MeetingNames.Span(name: "Max Mitchell", startMs: 5_000, endMs: 9_000),
        ], captions: nil)
        #expect(RoomVoices.silentNames(names, userName: "Max Mitchell") == ["Edie O'Neill"])
    }

    @Test func theUserIsNeverASilentName() {
        let names = MeetingNames(source: .roster, roster: ["Max Mitchell", "Ana"], channel: nil, spans: [], captions: nil)
        #expect(RoomVoices.silentNames(names, userName: "max mitchell") == ["Ana"])
    }

    @Test func aVoiceTheFarEndTalksOverIsEcho() {
        // A: the far end's words cover its time; B: the far end is quiet under it.
        let segments = [segment("A", 0, 10_000), segment("B", 10_000, 20_000)]
        #expect(RoomVoices.echoVoices(segments, farEnd: words(0, 10_000) + words(12_000, 12_500), echoShare: 0.3) == ["A"])
    }

    @Test func theLoudestVoiceIsItsNinetiethPercentile() {
        // A's segment is mostly pause with a loud stretch; B is steady and quieter than A's peaks.
        let envelope: [Float] = [0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.5, 0.5] + Array(repeating: 0.2, count: 10)
        let loudness = RoomVoices.loudness([segment("A", 0, 1_000), segment("B", 1_000, 2_000)], envelope: envelope, envelopeHz: 10)
        #expect(loudness == ["A": 0.5, "B": 0.2])
    }

    @Test func theLoudestVoiceIsTheUserAndTheOthersAreNumbered() {
        let segments = [segment("A", 0, 10_000), segment("B", 10_000, 20_000), segment("C", 20_000, 30_000), segment("B", 30_000, 40_000)]
        let split = RoomVoices.split(segments, echo: ["C"], loudness: ["A": 0.01, "B": 0.1, "C": 0.2])
        #expect(split == RoomVoices.Split(
            segments: [segment("r1", 0, 10_000), segment("you", 10_000, 20_000), segment("you", 20_000, 30_000), segment("you", 30_000, 40_000)],
            others: ["r1"]))
    }

    @Test func oneVoiceBesidesEchoLeavesTheMicAlone() {
        let segments = [segment("A", 0, 10_000), segment("B", 10_000, 20_000)]
        #expect(RoomVoices.split(segments, echo: ["B"], loudness: ["A": 0.1, "B": 0.2]) == nil)
    }
}
