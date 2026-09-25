import Foundation
import Testing
@testable import TypeMeIt

struct MeetingInsightsTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let now = ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")!

    private func meeting(_ started: String, minutes: Int, kind: Meeting.Kind = .call, app: String? = "Slack",
                         you: Int = 0, them: Int = 0, state: Meeting.Transcription.State = .done) -> Meeting {
        var m = MeetingFixtures.example
        m.id = UUID()
        m.kind = kind
        m.started = ISO8601DateFormatter().date(from: started)!
        m.durationMs = minutes * 60_000
        m.app = app.map { Meeting.App(bundleId: "b.\($0)", name: $0) }
        m.speakers = kind == .room ? [Meeting.Speaker(id: "s1", name: "Speaker 1", isYou: false, talkMs: them)]
            : [Meeting.Speaker(id: "you", name: "You", isYou: true, talkMs: you), Meeting.Speaker(id: "them", name: "Them", isYou: false, talkMs: them)]
        m.transcription.state = state
        return m
    }

    @Test func countsTimeTalkAndLengths() {
        let meetings = [
            meeting("2026-09-21T14:30:00Z", minutes: 11, you: 120_000, them: 360_000),
            meeting("2026-09-21T16:00:00Z", minutes: 47, app: "Google Chrome", you: 900_000, them: 600_000),
            meeting("2026-09-24T10:21:00Z", minutes: 11, you: 300_000, them: 150_000),
            meeting("2026-08-30T09:00:00Z", minutes: 30, kind: .room, app: nil, them: 1_000_000),
            meeting("2026-09-24T12:00:00Z", minutes: 5, state: .running),
        ]
        #expect(MeetingInsights.compute(meetings, now: now, calendar: calendar) == MeetingStats(
            meetings: 4, meetingsThisMonth: 3, totalMs: 99 * 60_000, thisMonthMs: 69 * 60_000,
            yourTalkMs: 1_320_000, callTalkMs: 2_430_000, medianMs: 11 * 60_000, longestMs: 47 * 60_000, topApp: "Slack"))
    }

    @Test func aMeetingSomeoneSharedIsNotCounted() {
        var shared = meeting("2026-09-21T16:00:00Z", minutes: 47, you: 900_000, them: 600_000)
        shared.sharedBy = "Ellen"
        let meetings = [meeting("2026-09-21T14:30:00Z", minutes: 11, you: 120_000, them: 360_000), shared]
        #expect(MeetingInsights.compute(meetings, now: now, calendar: calendar) == MeetingStats(
            meetings: 1, meetingsThisMonth: 1, totalMs: 11 * 60_000, thisMonthMs: 11 * 60_000,
            yourTalkMs: 120_000, callTalkMs: 480_000, medianMs: 11 * 60_000, longestMs: 11 * 60_000, topApp: "Slack"))
    }

    @Test func noMeetingsIsZeroes() {
        #expect(MeetingInsights.compute([], now: now, calendar: calendar) == MeetingStats(
            meetings: 0, meetingsThisMonth: 0, totalMs: 0, thisMonthMs: 0, yourTalkMs: 0, callTalkMs: 0, medianMs: nil, longestMs: nil, topApp: nil))
    }
}
