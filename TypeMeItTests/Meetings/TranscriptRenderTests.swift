import Testing
@testable import TypeMeIt

struct TranscriptRenderTests {
    @Test func timestampFormatsBelowAndPastAnHour() {
        #expect(TranscriptRender.timestamp(ms: 0) == "0:00")
        #expect(TranscriptRender.timestamp(ms: 14_000) == "0:14")
        #expect(TranscriptRender.timestamp(ms: 3_600_000) == "1:00:00")
        #expect(TranscriptRender.timestamp(ms: 3_661_000) == "1:01:01")
    }

    @Test func rendersTheExampleMeeting() {
        let expected = """
        ---
        title: "Slack"
        kind: call
        started: "2026-09-19 14:30 +01:00"
        duration: 35m
        app: "Slack"
        speakers: ["You", "Them"]
        echo: affected
        ---

        **You** · 0:14
        Morning. Shall we start with the deploy?

        **Them** · 0:21
        Sure, give me a second to pull it up.

        """
        #expect(TranscriptRender.markdown(MeetingFixtures.example) == expected)
    }

    @Test func aParagraphPastAnHourRendersHoursMinutesSeconds() {
        var meeting = MeetingFixtures.example
        meeting.paragraphs = [
            Meeting.Paragraph(speaker: "you", startMs: 3_661_000, endMs: 3_665_000, text: "Back after the break."),
        ]
        let expected = """
        ---
        title: "Slack"
        kind: call
        started: "2026-09-19 14:30 +01:00"
        duration: 35m
        app: "Slack"
        speakers: ["You", "Them"]
        echo: affected
        ---

        **You** · 1:01:01
        Back after the break.

        """
        #expect(TranscriptRender.markdown(meeting) == expected)
    }

    @Test func aQuoteOrBackslashInATitleIsEscapedAndARoomOmitsApp() {
        var meeting = MeetingFixtures.example
        meeting.title = "Q3 \"deploy\" \\ plan"
        meeting.app = nil
        meeting.kind = .room
        meeting.tracks = [Meeting.Track(role: .room, file: "room.m4a", frames: 0)]
        meeting.speakers = [Meeting.Speaker(id: "room", name: "Room", isYou: false, talkMs: 0)]
        meeting.paragraphs = [
            Meeting.Paragraph(speaker: "room", startMs: 5_000, endMs: 8_000, text: "Let's get started."),
        ]
        let expected = """
        ---
        title: "Q3 \\"deploy\\" \\\\ plan"
        kind: room
        started: "2026-09-19 14:30 +01:00"
        duration: 35m
        speakers: ["Room"]
        echo: affected
        ---

        **Room** · 0:05
        Let's get started.

        """
        #expect(TranscriptRender.markdown(meeting) == expected)
    }
}
