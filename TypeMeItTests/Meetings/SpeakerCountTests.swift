import Testing
@testable import TypeMeIt

struct SpeakerCountTests {
    private static let minimumMs = 10_000

    /// Back-to-back half-second words from `startMs` to `endMs`.
    private func words(_ startMs: Int, _ endMs: Int) -> [Transcriber.Word] {
        stride(from: startMs, to: endMs, by: 500).map {
            Transcriber.Word(text: "word", confidence: 1, start: .milliseconds($0), end: .milliseconds($0 + 500))
        }
    }

    private func span(_ name: String, _ startMs: Int, _ endMs: Int) -> MeetingNames.Span {
        MeetingNames.Span(name: name, startMs: startMs, endMs: endMs)
    }

    private func names(roster: [String], spans: [MeetingNames.Span] = []) -> MeetingNames {
        MeetingNames(source: spans.isEmpty ? .roster : .speaking, roster: roster, channel: nil, spans: spans, captions: nil)
    }

    @Test func theUserDropsOutUnderWhateverNameTheCallGivesThem() {
        // Meet shows the user's Google name, not the Mac's; their tile lights while the mic talks.
        let spans = [span("Max Mitchell", 0, 30_000), span("Ana", 30_000, 60_000)]
        let talkers = SpeakerCount.farEndTalkers(spans: spans, farEnd: words(30_000, 60_000), mic: words(0, 30_000), lagMs: 0, minimumMs: Self.minimumMs)
        #expect(talkers == ["Ana"])
    }

    @Test func theUsersTileIsTheNameLitWhileTheMicSpoke() {
        let spans = [span("Max Mitchell", 0, 30_000), span("Ana", 30_000, 60_000)]
        let user = SpeakerCount.userTile(spans: spans, farEnd: words(30_000, 60_000), mic: words(0, 30_000), lagMs: 0, minimumMs: Self.minimumMs)
        #expect(user == "Max Mitchell")
    }

    @Test func aUserWhoBarelySpokeHasNoTile() {
        let spans = [span("Max Mitchell", 0, 5_000), span("Ana", 5_000, 60_000)]
        let user = SpeakerCount.userTile(spans: spans, farEnd: words(5_000, 60_000), mic: words(0, 5_000), lagMs: 0, minimumMs: Self.minimumMs)
        #expect(user == nil)
    }

    @Test func crosstalkUnderTheUsersTileDoesNotMakeThemATalker() {
        // Twenty seconds of Ana talking over the user, inside the user's long turn.
        let spans = [span("Max Mitchell", 0, 120_000), span("Ana", 120_000, 150_000)]
        let talkers = SpeakerCount.farEndTalkers(
            spans: spans, farEnd: words(40_000, 60_000) + words(120_000, 150_000), mic: words(0, 120_000), lagMs: 0, minimumMs: Self.minimumMs)
        #expect(talkers == ["Ana"])
    }

    @Test func aTileLitByNoiseOrABriefWordIsNotATalker() {
        let spans = [span("Ana", 0, 30_000), span("Ben", 30_000, 40_000), span("Cy", 40_000, 45_000)]
        // Ben's tile lit over silence; Cy said five seconds.
        let talkers = SpeakerCount.farEndTalkers(
            spans: spans, farEnd: words(0, 30_000) + words(40_000, 45_000), mic: [], lagMs: 0, minimumMs: Self.minimumMs)
        #expect(talkers == ["Ana"])
    }

    @Test func spansAreMovedBackByTheIndicatorLag() {
        // Recorded 400 ms after the voice: without the shift Ana would end short of ten seconds.
        let spans = [span("Ana", 400, 10_400)]
        #expect(SpeakerCount.farEndTalkers(spans: spans, farEnd: words(0, 10_000), mic: [], lagMs: 400, minimumMs: Self.minimumMs) == ["Ana"])
        #expect(SpeakerCount.farEndTalkers(spans: spans, farEnd: words(0, 10_000), mic: [], lagMs: 0, minimumMs: Self.minimumMs).isEmpty)
    }

    @Test func turnsAddUpAcrossTheCall() {
        let spans = [span("Ana", 0, 6_000), span("Ben", 6_000, 20_000), span("Ana", 20_000, 26_000)]
        let talkers = SpeakerCount.farEndTalkers(spans: spans, farEnd: words(0, 26_000), mic: [], lagMs: 0, minimumMs: Self.minimumMs)
        #expect(talkers == ["Ana", "Ben"])
    }

    @Test func peopleShownTalkingSetTheCountExactly() {
        let names = names(roster: ["Ana", "Ben", "Cy"], spans: [span("Ana", 0, 1), span("Ben", 1, 2)])
        #expect(SpeakerCount.of(names, talkers: ["Ana", "Ben"], userName: nil) == .exactly(2))
    }

    @Test func theListAloneOnlyCapsTheCount() {
        let names = names(roster: ["Ana", "Ben", "Maximilian Mitchell"])
        #expect(SpeakerCount.of(names, talkers: [], userName: "maximilian mitchell") == .atMost(2))
    }

    @Test func aWindowThatShowedNobodySaysNothing() {
        #expect(SpeakerCount.of(names(roster: []), talkers: [], userName: nil) == nil)
        #expect(SpeakerCount.of(names(roster: ["Maximilian Mitchell"]), talkers: [], userName: "Maximilian Mitchell") == nil)
    }
}
