import Foundation
import Testing
@testable import TypeMeIt

struct MeetingPhaseTests {
    private static let named = Meeting.Speaker(id: "them", name: "Ana", isYou: false, talkMs: 1_000, nameSource: .user)
    private static let unnamed = Meeting.Speaker(id: "s2", name: Meeting.Speaker.numberedName(2), isYou: false, talkMs: 1_000)
    private static let run = MeetingCoordinator.Transcribing(id: MeetingFixtures.example.id, progress: .transcribing(0.4))

    private func meeting(_ state: Meeting.Transcription.State = .done, speakers: [Meeting.Speaker] = [named], summary: String? = "Deploy moved to friday.") -> Meeting {
        var meeting = MeetingFixtures.example
        meeting.transcription.state = state
        meeting.speakers = speakers
        meeting.summary = summary
        return meeting
    }

    private func phase(_ meeting: Meeting, transcribing: MeetingCoordinator.Transcribing? = nil, queued: Bool = false,
                       summarising: Bool = false, hasChips: Bool = false) -> MeetingPhase {
        MeetingState.phase(meeting, transcribing: transcribing, queued: queued, summarising: summarising, hasChips: hasChips)
    }

    @Test func itsOwnRunComesFirst() {
        #expect(phase(meeting(.running), transcribing: Self.run, queued: true, summarising: true, hasChips: true) == .transcribing(Self.run))
    }

    @Test func anotherMeetingsRunIsNotThisOnes() {
        let other = MeetingCoordinator.Transcribing(id: UUID(), progress: .transcribing(0.4))
        #expect(phase(meeting(.pending), transcribing: other, queued: true) == .queued)
    }

    @Test func queuedComesBeforeSummarising() {
        #expect(phase(meeting(.pending), queued: true, summarising: true) == .queued)
    }

    @Test func summarisingHidesAnEarlierSummary() {
        #expect(phase(meeting(), summarising: true, hasChips: true) == .summarising)
    }

    @Test func needsComeBeforeUnknownSpeakers() {
        #expect(phase(meeting(speakers: [Self.unnamed]), hasChips: true) == .needs)
    }

    @Test func aDoneMeetingCountsItsUnknownSpeakers() {
        #expect(phase(meeting(speakers: [Self.unnamed, Self.named, Self.unnamed])) == .unknownSpeakers(2))
    }

    @Test func anUnfinishedMeetingDoesNotAskForNames() {
        #expect(phase(meeting(.failed, speakers: [Self.unnamed])) == .summary("Deploy moved to friday."))
    }

    @Test func otherwiseItsSummaryOrNothing() {
        #expect(phase(meeting()) == .summary("Deploy moved to friday."))
        #expect(phase(meeting(summary: "")) == .none)
        #expect(phase(meeting(summary: nil)) == .none)
    }
}
