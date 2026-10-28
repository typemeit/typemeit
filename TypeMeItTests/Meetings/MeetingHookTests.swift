import Foundation
import Testing
@testable import TypeMeIt

struct MeetingHookTests {
    private let decisions = MeetingHook(name: "decisions", prompt: "list each decision")
    private let actions = MeetingHook(name: "action items", prompt: "list the action items")

    private func meeting(_ runs: [(name: String, failed: Bool)]) -> Meeting {
        var meeting = MeetingFixtures.meeting()
        meeting.hookRuns = runs.map { Meeting.HookRun(id: UUID(), name: $0.name, prompt: "", ranAt: Date(), output: "", failed: $0.failed) }
        return meeting
    }

    @Test func everyHookRunsOnAMeetingWithNoRuns() {
        #expect(MeetingHook.notYetRun([decisions, actions], on: meeting([])) == [decisions, actions])
    }

    @Test func aHookThatRanIsNotRunAgain() {
        #expect(MeetingHook.notYetRun([decisions, actions], on: meeting([("decisions", false)])) == [actions])
    }

    @Test func aHookThatFailedRunsAgain() {
        #expect(MeetingHook.notYetRun([decisions, actions], on: meeting([("decisions", true), ("action items", false)])) == [decisions])
    }
}
