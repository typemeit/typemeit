import Testing
@testable import TypeMeIt

struct RosterAccumulatorTests {
    private func reading(_ roster: [String] = [], speaking: Set<String> = [], captions: [RosterReading.Caption] = []) -> RosterReading {
        RosterReading(roster: roster, speaking: speaking, captions: captions)
    }

    @Test func turnsBecomeSpans() {
        var a = RosterAccumulator(minimumSpanMs: 250)
        a.add(reading(["Ana", "Ben"], speaking: ["Ana"]), atMs: 0)
        a.add(reading(["Ana", "Ben"], speaking: ["Ana"]), atMs: 1000)
        a.add(reading(["Ana", "Ben"], speaking: ["Ben"]), atMs: 2000)
        a.add(reading(["Ana", "Ben"]), atMs: 3000)
        #expect(a.finish(atMs: 3000) == MeetingNames(
            source: .speaking, roster: ["Ana", "Ben"], channel: nil,
            spans: [MeetingNames.Span(name: "Ana", startMs: 0, endMs: 2000), MeetingNames.Span(name: "Ben", startMs: 2000, endMs: 3000)],
            captions: nil))
    }

    @Test func aBlipShorterThanTheMinimumIsNotATurn() {
        var a = RosterAccumulator(minimumSpanMs: 250)
        a.add(reading(["Ana"], speaking: ["Ana"]), atMs: 0)
        a.add(reading(["Ana"]), atMs: 200)
        #expect(a.finish(atMs: 500) == MeetingNames(source: .roster, roster: ["Ana"], channel: nil, spans: [], captions: nil))
    }

    @Test func twoTurnsAPollApartAreOne() {
        var a = RosterAccumulator(minimumSpanMs: 250)
        a.add(reading(speaking: ["Ana"]), atMs: 0)
        a.add(reading(), atMs: 1000)
        a.add(reading(speaking: ["Ana"]), atMs: 1250)
        a.add(reading(), atMs: 2000)
        #expect(a.finish(atMs: 2000)?.spans == [MeetingNames.Span(name: "Ana", startMs: 0, endMs: 2000)])
    }

    @Test func anOpenTurnClosesAtTheEnd() {
        var a = RosterAccumulator(minimumSpanMs: 250)
        a.add(reading(speaking: ["Ana"]), atMs: 1000)
        #expect(a.finish(atMs: 4000)?.spans == [MeetingNames.Span(name: "Ana", startMs: 1000, endMs: 4000)])
    }

    @Test func aGrowingCaptionLineIsOneCaption() {
        var a = RosterAccumulator(minimumSpanMs: 250)
        a.add(reading(captions: [.init(name: "Ana", text: "so the")]), atMs: 0)
        a.add(reading(captions: [.init(name: "Ana", text: "so the plan is")]), atMs: 500)
        a.add(reading(captions: [.init(name: "Ben", text: "right")]), atMs: 1000)
        #expect(a.finish(atMs: 1000) == MeetingNames(
            source: .captions, roster: [], channel: nil, spans: [],
            captions: [MeetingNames.Caption(name: "Ana", startMs: 0, text: "so the plan is"), MeetingNames.Caption(name: "Ben", startMs: 1000, text: "right")]))
    }

    @Test func nothingReadIsNil() {
        var a = RosterAccumulator(minimumSpanMs: 250)
        a.add(reading(), atMs: 0)
        #expect(a.finish(atMs: 1000) == nil)
    }
}
