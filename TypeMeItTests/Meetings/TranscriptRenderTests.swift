import Foundation
import Testing
@testable import TypeMeIt

struct TranscriptRenderTests {
    @Test func timestampFormatsBelowAndPastAnHour() {
        #expect(TranscriptRender.timestamp(ms: 0) == "0:00")
        #expect(TranscriptRender.timestamp(ms: 14_000) == "0:14")
        #expect(TranscriptRender.timestamp(ms: 3_600_000) == "1:00:00")
        #expect(TranscriptRender.timestamp(ms: 3_661_000) == "1:01:01")
    }

    /// The player's clock: a part second still shows the second it is in.
    @Test func timestampRoundsAPartSecondDown() {
        #expect(TranscriptRender.timestamp(ms: 3_999) == "0:03")
        #expect(TranscriptRender.timestamp(ms: 724_900) == "12:04")
    }

    @Test func rendersTheExampleMeeting() {
        let expected = """
        ---
        title: "Slack"
        kind: call
        started: "2026-09-19 14:30 +01:00"
        duration: 34:36
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

    /// What a hook reads: the name the user gave beside the one the call
    /// showed, a name only the call gave, and whom each voice sounds like.
    @Test func speakersSayWhereEachNameCameFrom() {
        var meeting = MeetingFixtures.example
        meeting.speakers = [
            Meeting.Speaker(id: "you", name: "You", isYou: true, talkMs: 394_000),
            Meeting.Speaker(id: "s1", name: "Ines Varga", isYou: false, talkMs: 700_000, nameSource: .user,
                            predicted: Meeting.Speaker.Prediction(name: "Theo Brandt", source: .speaking)),
            Meeting.Speaker(id: "s2", name: "Rosa Pell", isYou: false, talkMs: 713_000, nameSource: .captions),
            Meeting.Speaker(id: "s3", name: "Speaker 3", isYou: false, talkMs: 0),
        ]
        meeting.paragraphs = [
            Meeting.Paragraph(speaker: "s1", startMs: 14_000, endMs: 21_000, text: "Deploy went out at nine."),
            Meeting.Paragraph(speaker: "s2", startMs: 21_000, endMs: 30_000, text: "I'm on the billing bug today."),
        ]
        let voices = [
            "s1": Meeting.Speaker.VoiceGuess(name: "Theo Brandt", posterior: 0.548),
            "s2": Meeting.Speaker.VoiceGuess(name: "Rosa Pell", posterior: 0.97),
        ]
        let expected = """
        ---
        title: "Slack"
        kind: call
        started: "2026-09-19 14:30 +01:00"
        duration: 34:36
        app: "Slack"
        speakers: ["You", "Ines Varga", "Rosa Pell", "Speaker 3"]
        echo: affected
        ---

        ## Speakers

        - **Ines Varga**: named by the user; the call's speaking indicator said Theo Brandt; voice matches Theo Brandt (55%)
        - **Rosa Pell**: named from the call's captions; voice matches Rosa Pell (97%)

        ## Transcript

        **Ines Varga** · 0:14
        Deploy went out at nine.

        **Rosa Pell** · 0:21
        I'm on the billing bug today.

        """
        #expect(TranscriptRender.markdown(meeting, voices: voices) == expected)
    }

    @Test func questionsOfferedToClaudeFollowTheTranscript() {
        var meeting = MeetingFixtures.example
        meeting.questions = [
            Meeting.Question(atMs: 75_000, text: "How many calls came in last week?", answer: "**1,284** inbound calls."),
            Meeting.Question(atMs: 90_000, text: "Which table has the inquiries?", outcome: .dismissed),
            Meeting.Question(atMs: 125_000, text: "Is the export done?", outcome: .ignored),
        ]
        let expected = """
        ---
        title: "Slack"
        kind: call
        started: "2026-09-19 14:30 +01:00"
        duration: 34:36
        app: "Slack"
        speakers: ["You", "Them"]
        echo: affected
        ---

        **You** · 0:14
        Morning. Shall we start with the deploy?

        **Them** · 0:21
        Sure, give me a second to pull it up.

        ## Questions for Claude

        ### How many calls came in last week? · 1:15

        **1,284** inbound calls.

        ### Which table has the inquiries? · 1:30 · dismissed

        ### Is the export done? · 2:05 · not asked

        """
        #expect(TranscriptRender.markdown(meeting) == expected)
    }

    @Test func aSaveKeepsQuestionsEitherCopyHas() {
        let first = Meeting.Question(atMs: 10_000, text: "Which table?", answer: "calls")
        let second = Meeting.Question(atMs: 5_000, text: "How many?", answer: "12")
        #expect(Meeting.Question.union([first], [second, first]) == [second, first])
    }

    @Test func aQuestionFollowsTheTurnItWasHeardIn() {
        var meeting = MeetingFixtures.example
        meeting.questions = [
            Meeting.Question(atMs: 30_000, text: "Is the export done?", outcome: .ignored),
            Meeting.Question(atMs: 15_000, text: "Which deploy?", outcome: .dismissed),
            Meeting.Question(atMs: 5_000, text: "Who is on call?", outcome: .dismissed),
        ]
        #expect(TranscriptRender.entries(meeting) == [.question(2), .paragraph(0), .question(1), .paragraph(1), .question(0)])
    }

    @Test func anAsideIsShownInsideTheTurnItWasSaidIn() {
        var meeting = MeetingFixtures.example
        meeting.paragraphs = [
            Meeting.Paragraph(speaker: "them", startMs: 14_000, endMs: 17_000, text: "The deploy went out at noon."),
            Meeting.Paragraph(speaker: "you", startMs: 17_200, endMs: 17_800, text: "Exactly.", aside: true),
            Meeting.Paragraph(speaker: "them", startMs: 17_500, endMs: 19_000, text: "Then the export."),
            Meeting.Paragraph(speaker: "you", startMs: 21_000, endMs: 22_000, text: "Shall we start?"),
        ]
        #expect(TranscriptRender.rows(meeting.paragraphs) == [[0, 1, 2], [3]])
        #expect(TranscriptRender.paragraphs(meeting) == """
        **Them** · 0:14
        The deploy went out at noon. [You: Exactly.] Then the export.

        **You** · 0:21
        Shall we start?
        """)
        #expect(TranscriptRender.entries(meeting) == [.paragraph(0), .paragraph(3)])
    }

    @Test func anAsideMergedIntoTheTurnsOwnSpeakerReadsAsTheTurn() {
        let paragraphs = [
            Meeting.Paragraph(speaker: "them", startMs: 0, endMs: 3_000, text: "First."),
            Meeting.Paragraph(speaker: "them", startMs: 3_100, endMs: 3_500, text: "Yes.", mergedFrom: "s2", aside: true),
            Meeting.Paragraph(speaker: "them", startMs: 3_200, endMs: 5_000, text: "Second."),
        ]
        #expect(TranscriptRender.rows(paragraphs) == [[0, 1, 2]])
        #expect(!TranscriptRender.bracketed(1, in: [0, 1, 2], of: paragraphs))
    }

    @Test func aQuestionKeptBeforeOutcomesWereIsAsked() throws {
        let kept = Data(#"{"atMs":75000,"text":"How many calls came in?","answer":"12"}"#.utf8)
        #expect(try JSONDecoder().decode(Meeting.Question.self, from: kept).result == .asked)
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
        duration: 34:36
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
        duration: 34:36
        speakers: ["Room"]
        echo: affected
        ---

        **Room** · 0:05
        Let's get started.

        """
        #expect(TranscriptRender.markdown(meeting) == expected)
    }

    @Test func hookOutputFollowsTheQuestions() {
        var meeting = MeetingFixtures.example
        meeting.hookRuns = [
            Meeting.HookRun(id: UUID(), name: "action items", prompt: "List the action items.", ranAt: Date(timeIntervalSince1970: 1_790_000_000),
                            output: "- Pull up the deploy", failed: false, sessionID: "2f1c9a4e-0000-4000-8000-000000000001"),
            Meeting.HookRun(id: UUID(), name: "to linear", prompt: "File the action items in Linear.", ranAt: Date(timeIntervalSince1970: 1_790_000_060),
                            output: "Claude Code stopped before answering.", failed: true),
        ]
        let expected = """
        ---
        title: "Slack"
        kind: call
        started: "2026-09-19 14:30 +01:00"
        duration: 34:36
        app: "Slack"
        speakers: ["You", "Them"]
        echo: affected
        ---

        **You** · 0:14
        Morning. Shall we start with the deploy?

        **Them** · 0:21
        Sure, give me a second to pull it up.

        ## Hooks

        ### action items

        - Pull up the deploy

        claude --resume 2f1c9a4e-0000-4000-8000-000000000001

        ### to linear · failed

        Claude Code stopped before answering.

        """
        #expect(TranscriptRender.markdown(meeting) == expected)
    }

    @Test func aSaveKeepsHookRunsEitherCopyHas() {
        let earlier = Meeting.HookRun(id: UUID(), name: "summary", prompt: "Summarise it.", ranAt: Date(timeIntervalSince1970: 100), output: "short", failed: false)
        let later = Meeting.HookRun(id: UUID(), name: "tickets", prompt: "File tickets.", ranAt: Date(timeIntervalSince1970: 200), output: "filed 2", failed: false)
        #expect(Meeting.HookRun.union([later], [earlier, later]) == [earlier, later])
    }

    @Test func thePillSaysHowTheHooksWent() {
        #expect(PillView.hooksDone(ran: 1, failed: 0) == "hook done")
        #expect(PillView.hooksDone(ran: 3, failed: 0) == "3 hooks done")
        #expect(PillView.hooksDone(ran: 1, failed: 1) == "hook failed")
        #expect(PillView.hooksDone(ran: 2, failed: 2) == "2 hooks failed")
        #expect(PillView.hooksDone(ran: 3, failed: 1) == "1 of 3 hooks failed")
    }
}
