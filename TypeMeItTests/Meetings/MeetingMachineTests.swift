import Foundation
import Testing
@testable import TypeMeIt

/// Walks the machine with an injected clock: `t0` is the start and every
/// event is placed at a number of seconds after it.
private struct Sim {
    typealias Owner = ProcessOwner.Owner
    typealias Holder = MeetingWatch.Holder
    typealias Event = MeetingMachine.Event
    typealias Effect = MeetingMachine.Effect

    static let slack = Owner(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", appURL: nil)
    static let chrome = Owner(bundleID: "com.google.Chrome", name: "Google Chrome", appURL: nil)

    var machine = MeetingMachine()
    var rules = MeetingMachine.Rules.fixed
    let t0 = ContinuousClock.now
    /// Every effect so far, in order.
    var effects: [Effect] = []

    var state: MeetingMachine.State { machine.state }

    static func holders(_ entries: [(Owner, input: Bool, output: Bool)]) -> Event {
        .holders(entries.map { Holder(owner: $0.0, objectIDs: [1], input: $0.input, output: $0.output) })
    }

    @discardableResult
    mutating func at(_ seconds: Int, _ event: Event) -> [Effect] {
        let out = machine.handle(event, now: t0 + .seconds(seconds), rules: rules)
        effects += out
        return out
    }

    /// One tick a second from `from` through `to`.
    @discardableResult
    mutating func ticks(_ from: Int, _ to: Int) -> [Effect] {
        var out: [Effect] = []
        for s in from...to { out += at(s, .tick(t0 + .seconds(s))) }
        return out
    }

    /// Seeds the machine with nobody holding the mic, then has `owner` open
    /// input (and output) at second 1.
    mutating func openCall(_ owner: Owner = slack, output: Bool = true) {
        at(0, Sim.holders([]))
        at(1, Sim.holders([(owner, input: true, output: output)]))
    }

    /// Seeds, opens a call, waits for the prompt and clicks record at
    /// second 14. Returns the effects of the click.
    @discardableResult
    mutating func recordCall(_ owner: Owner = slack) -> [Effect] {
        openCall(owner)
        ticks(1, 13)
        return at(14, .record(owner))
    }

    func count(_ effect: Effect) -> Int { effects.filter { $0 == effect }.count }
}

struct MeetingMachineTests {
    private typealias S = Sim

    @Test func startsIdle() {
        #expect(MeetingMachine().state == .idle)
    }

    @Test func inputAloneNeverPrompts() {
        var s = S()
        s.openCall(output: false)
        let out = s.ticks(1, 91)
        #expect(out == [.discardPreRoll])
        #expect(s.count(.showPrompt(S.slack)) == 0)
    }

    @Test func armTimeoutSendsTheCandidateBackToIdleUntilInputDrops() {
        var s = S()
        s.openCall(output: false)
        s.ticks(1, 91)
        #expect(s.state == .idle)
        // Output joining afterwards does not re-arm it.
        s.at(92, S.holders([(S.slack, input: true, output: true)]))
        s.ticks(92, 110)
        #expect(s.state == .idle)
        // Input dropping and returning does.
        s.at(111, S.holders([]))
        s.at(112, S.holders([(S.slack, input: true, output: true)]))
        s.ticks(112, 124)
        #expect(s.count(.showPrompt(S.slack)) == 1)
    }

    @Test func elevenSecondsOfBothThenOffNeverPrompts() {
        var s = S()
        s.openCall()
        s.ticks(1, 11)
        s.at(12, S.holders([]))
        s.ticks(12, 30)
        #expect(s.count(.showPrompt(S.slack)) == 0)
        #expect(s.state == .idle)
    }

    @Test func twelveSecondsOfBothPrompts() {
        var s = S()
        s.openCall()
        #expect(s.ticks(1, 12) == [])
        #expect(s.at(13, .tick(s.t0 + .seconds(13))) == [.showPrompt(S.slack)])
        #expect(s.state == .prompting(owner: S.slack, since: s.t0 + .seconds(13)))
    }

    @Test func outputDroppingRestartsTheConfirmWindow() {
        var s = S()
        s.at(0, S.holders([]))
        s.at(0, S.holders([(S.slack, input: true, output: false)]))
        s.at(11, S.holders([(S.slack, input: true, output: true)]))
        s.at(12, S.holders([(S.slack, input: true, output: false)]))
        s.at(13, S.holders([(S.slack, input: true, output: true)]))
        s.ticks(13, 24)
        #expect(s.count(.showPrompt(S.slack)) == 0)
        s.ticks(25, 25)
        #expect(s.count(.showPrompt(S.slack)) == 1)
    }

    @Test func candidateInputOffGoesIdle() {
        var s = S()
        s.openCall()
        s.at(5, S.holders([]))
        #expect(s.state == .idle)
    }

    @Test func recordFromThePromptStartsARecording() {
        var s = S()
        let out = s.recordCall()
        #expect(out == [.hidePrompt, .startRecording(S.slack)])
        #expect(s.state == .recording(owner: S.slack, since: s.t0 + .seconds(14)))
    }

    @Test func recordForAnotherOwnerWhilePromptingIsIgnored() {
        var s = S()
        s.openCall()
        s.ticks(1, 13)
        #expect(s.at(14, .record(S.chrome)) == [])
        #expect(s.state == .prompting(owner: S.slack, since: s.t0 + .seconds(13)))
    }

    @Test func declineIsRememberedAcrossADropAndRejoin() {
        var s = S()
        s.openCall()
        s.ticks(1, 13)
        #expect(s.at(14, .decline) == [.hidePrompt, .discardPreRoll])
        #expect(s.state == .declined(owner: S.slack))
        s.at(20, S.holders([]))
        #expect(s.state == .paused(owner: S.slack, since: s.t0 + .seconds(20), before: .declined))
        s.ticks(20, 50)
        s.at(50, S.holders([(S.slack, input: true, output: true)]))
        s.ticks(50, 80)
        #expect(s.state == .declined(owner: S.slack))
        #expect(s.count(.showPrompt(S.slack)) == 1)
    }

    @Test func declineIsForgottenAfterTheRejoinWindow() {
        var s = S()
        s.openCall()
        s.ticks(1, 13)
        s.at(14, .decline)
        s.at(20, S.holders([]))
        s.ticks(20, 141)
        #expect(s.state == .idle)
        s.at(142, S.holders([(S.slack, input: true, output: true)]))
        s.ticks(142, 155)
        #expect(s.count(.showPrompt(S.slack)) == 2)
    }

    @Test func recordAfterADeclineStartsARecording() {
        var s = S()
        s.openCall()
        s.ticks(1, 13)
        s.at(14, .decline)
        #expect(s.at(20, .record(S.slack)) == [.startRecording(S.slack)])
        #expect(s.state == .recording(owner: S.slack, since: s.t0 + .seconds(20)))
    }

    @Test func aShortDropPausesAndResumesOneRecording() {
        var s = S()
        s.recordCall()
        #expect(s.at(100, S.holders([])) == [.pauseRecording])
        s.ticks(100, 119)
        #expect(s.at(120, S.holders([(S.slack, input: true, output: true)])) == [.resumeRecording, .showResumed(S.slack)])
        #expect(s.state == .recording(owner: S.slack, since: s.t0 + .seconds(14)))
        #expect(s.count(.startRecording(S.slack)) == 1)
        #expect(s.count(.pauseRecording) == 1)
        #expect(s.count(.resumeRecording) == 1)
        #expect(s.count(.showResumed(S.slack)) == 1)
    }

    @Test func aLongDropFinishesTheRecording() {
        var s = S()
        s.recordCall()
        s.at(100, S.holders([]))
        s.ticks(100, 129)
        #expect(s.state == .paused(owner: S.slack, since: s.t0 + .seconds(100), before: .recording))
        #expect(s.ticks(130, 130) == [.stopRecording])
        #expect(s.state == .finishing(owner: S.slack))
    }

    @Test func anOwnerAlreadyHoldingInputAtStartNeverPrompts() {
        var s = S()
        s.at(0, S.holders([(S.slack, input: true, output: true)]))
        s.ticks(0, 60)
        #expect(s.state == .idle)
        #expect(s.at(61, .record(S.slack)) == [.startRecording(S.slack)])
        #expect(s.state == .recording(owner: S.slack, since: s.t0 + .seconds(61)))
    }

    @Test func promptSurvivesAShortDropAndRecordThenRecords() {
        var s = S()
        s.openCall()
        s.ticks(1, 13)
        #expect(s.at(14, S.holders([])) == [.hidePrompt, .discardPreRoll])
        s.ticks(14, 18)
        #expect(s.at(19, S.holders([(S.slack, input: true, output: true)])) == [.showPrompt(S.slack)])
        #expect(s.at(20, .record(S.slack)) == [.hidePrompt, .startRecording(S.slack)])
    }

    @Test func promptComesBackAfterATenSecondDrop() {
        var s = S()
        s.openCall()
        s.ticks(1, 13)
        s.at(14, S.holders([]))
        s.ticks(14, 23)
        s.at(24, S.holders([(S.slack, input: true, output: true)]))
        #expect(s.count(.showPrompt(S.slack)) == 2)
    }

    @Test func recordWhilePausedOnAPromptStartsARecording() {
        var s = S()
        s.openCall()
        s.ticks(1, 13)
        s.at(14, S.holders([]))
        #expect(s.at(15, .record(S.slack)) == [.startRecording(S.slack)])
    }

    @Test func aDifferentOwnerWhilePromptingRestartsAsACandidate() {
        var s = S()
        s.openCall()
        s.ticks(1, 13)
        let out = s.at(14, S.holders([(S.slack, input: true, output: true), (S.chrome, input: true, output: true)]))
        #expect(out == [.hidePrompt, .discardPreRoll, .beginPreRoll(S.chrome)])
        #expect(s.state == .candidate(owner: S.chrome, since: s.t0 + .seconds(14), bothSince: s.t0 + .seconds(14)))
    }

    @Test func bothSilentFinishesARecording() {
        var s = S()
        s.recordCall()
        #expect(s.at(700, .bothSilent) == [.stopRecording])
        #expect(s.state == .finishing(owner: S.slack))
    }

    @Test func stopFinishesARecording() {
        var s = S()
        s.recordCall()
        #expect(s.at(100, .stop) == [.stopRecording])
        #expect(s.at(101, .recorderEnded(recordedMs: 86_000)) == [.finished(keep: false)])
        #expect(s.state == .idle)
    }

    @Test func stopWhilePausedFinishesTheRecording() {
        var s = S()
        s.recordCall()
        s.at(100, S.holders([]))
        #expect(s.at(105, .stop) == [.stopRecording])
        #expect(s.state == .finishing(owner: S.slack))
    }

    @Test func roomWhileACallRecordsChangesNothing() {
        var s = S()
        s.recordCall()
        #expect(s.at(100, .room) == [])
        #expect(s.state == .recording(owner: S.slack, since: s.t0 + .seconds(14)))
    }

    @Test func aCallStartingWhileTheRoomRecordsChangesNothing() {
        var s = S()
        s.at(0, S.holders([]))
        #expect(s.at(1, .room) == [.startRecording(nil)])
        s.at(10, S.holders([(S.slack, input: true, output: true)]))
        s.ticks(10, 40)
        #expect(s.state == .recording(owner: nil, since: s.t0 + .seconds(1)))
        #expect(s.count(.showPrompt(S.slack)) == 0)
    }

    @Test func roomGivesWayToNothingButItsOwnStop() {
        var s = S()
        s.at(0, S.holders([]))
        s.at(1, .room)
        s.at(10, S.holders([(S.slack, input: true, output: true)]))
        s.at(11, S.holders([]))
        #expect(s.state == .recording(owner: nil, since: s.t0 + .seconds(1)))
        #expect(s.at(21, .stop) == [.stopRecording])
        #expect(s.at(22, .recorderEnded(recordedMs: 20_000)) == [.finished(keep: true)])
    }

    @Test func roomWhilePromptingTakesThePromptDown() {
        var s = S()
        s.openCall()
        s.ticks(1, 13)
        #expect(s.at(14, .room) == [.hidePrompt, .discardPreRoll, .startRecording(nil)])
    }

    @Test func aShortCallIsDroppedAndALongerOneKept() {
        var short = S()
        short.recordCall()
        short.at(100, .stop)
        #expect(short.at(101, .recorderEnded(recordedMs: 89_000)) == [.finished(keep: false)])

        var long = S()
        long.recordCall()
        long.at(110, .stop)
        #expect(long.at(111, .recorderEnded(recordedMs: 91_000)) == [.finished(keep: true)])
    }

    @Test func willSleepFinishesARecording() {
        var s = S()
        s.recordCall()
        #expect(s.at(100, .willSleep) == [.stopRecording])
        #expect(s.state == .finishing(owner: S.slack))
    }

    @Test func willSleepTakesAPromptDown() {
        var s = S()
        s.openCall()
        s.ticks(1, 13)
        #expect(s.at(14, .willSleep) == [.hidePrompt, .discardPreRoll])
        #expect(s.state == .idle)
    }

    @Test func theFirstHoldersAfterWakingOnlySeeds() {
        var s = S()
        s.at(0, S.holders([]))
        s.at(1, .didWake)
        s.at(2, S.holders([(S.slack, input: true, output: true)]))
        s.ticks(2, 30)
        #expect(s.state == .idle)
        s.at(31, S.holders([]))
        s.at(32, S.holders([(S.slack, input: true, output: true)]))
        s.ticks(32, 45)
        #expect(s.count(.showPrompt(S.slack)) == 1)
    }

    @Test func sessionCapStopsARecordingThatNeverEnds() {
        var s = S()
        s.rules.sessionCap = .seconds(60)
        s.recordCall()
        s.ticks(15, 73)
        #expect(s.state == .recording(owner: S.slack, since: s.t0 + .seconds(14)))
        #expect(s.ticks(74, 74) == [.stopRecording])
    }

    @Test func sessionCapCountsFromTheStartAcrossAPause() {
        var s = S()
        s.rules.sessionCap = .seconds(60)
        s.recordCall()
        s.at(30, S.holders([]))
        s.at(40, S.holders([(S.slack, input: true, output: true)]))
        s.ticks(40, 73)
        #expect(s.state == .recording(owner: S.slack, since: s.t0 + .seconds(14)))
        #expect(s.ticks(74, 74) == [.stopRecording])
    }

    @Test func theEarlierCandidateWinsUnlessALaterOneHasBothFlags() {
        var s = S()
        s.at(0, S.holders([]))
        s.at(1, S.holders([(S.slack, input: true, output: false)]))
        s.at(2, S.holders([(S.slack, input: true, output: false), (S.chrome, input: true, output: false)]))
        #expect(s.state == .candidate(owner: S.slack, since: s.t0 + .seconds(1), bothSince: nil))
        s.at(3, S.holders([(S.slack, input: true, output: false), (S.chrome, input: true, output: false)]))
        s.at(4, S.holders([(S.slack, input: true, output: false)]))
        s.at(5, S.holders([(S.slack, input: true, output: false), (S.chrome, input: true, output: true)]))
        #expect(s.state == .candidate(owner: S.chrome, since: s.t0 + .seconds(5), bothSince: s.t0 + .seconds(5)))
    }

    // MARK: Pre-roll (D20)

    @Test func aCandidateBeginsThePreRoll() {
        var s = S()
        s.at(0, S.holders([]))
        #expect(s.at(1, S.holders([(S.slack, input: true, output: true)])) == [.beginPreRoll(S.slack)])
    }

    @Test func theCandidateLapsingDiscardsIt() {
        var s = S()
        s.openCall(output: false)
        s.ticks(1, 90)
        #expect(s.ticks(91, 91) == [.discardPreRoll])
    }

    @Test func inputDroppingBeforeThePromptDiscardsIt() {
        var s = S()
        s.openCall()
        #expect(s.at(5, S.holders([])) == [.discardPreRoll])
    }

    @Test func recordAfterThePreRollStartsTheRecordingForThatOwner() {
        var s = S()
        s.openCall()
        s.ticks(1, 13)
        #expect(s.at(14, .record(S.slack)) == [.hidePrompt, .startRecording(S.slack)])
        #expect(s.count(.beginPreRoll(S.slack)) == 1)
        #expect(s.count(.discardPreRoll) == 0)
    }
}
