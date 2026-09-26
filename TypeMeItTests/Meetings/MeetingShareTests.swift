import Foundation
import Testing
@testable import TypeMeIt

struct MeetingShareTests {
    private let sender = "Max Mitchell"

    @Test func writesTheExampleMeeting() {
        let expected = """
        ---
        title: "Slack"
        kind: call
        started: "2026-09-19 14:30 +01:00"
        duration: 34:36
        app: "Slack"
        speakers: ["Max Mitchell", "Them"]
        from: "Max Mitchell"
        id: 9F2C0000-0000-0000-0000-000000000000
        format: 1
        ---

        typeme.it

        **Max Mitchell** · 0:14
        Morning. Shall we start with the deploy?

        **Them** · 0:21
        Sure, give me a second to pull it up.

        """
        #expect(MeetingShare.markdown(MeetingFixtures.example, sender: sender) == expected)
    }

    @Test func theFileIsNamedLikeTheMeetingsFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try MeetingFolder.writeShare(MeetingFixtures.example, sender: sender, into: dir)
        #expect(file.lastPathComponent == "2026-09-19 1430 35m Slack.tmi")
        #expect(try String(contentsOf: file, encoding: .utf8) == MeetingShare.markdown(MeetingFixtures.example, sender: sender))
    }

    @Test func readsBackWhatItWrites() throws {
        let m = try MeetingShare.meeting(from: MeetingShare.markdown(MeetingFixtures.example, sender: sender))
        #expect(m.id == MeetingFixtures.example.id)
        #expect(m.title == "Slack")
        #expect(m.kind == .call)
        // The file keeps the minute, in the offset the meeting was in.
        #expect(m.started == Date(timeIntervalSince1970: 1_789_824_600))
        #expect(TimeZone(identifier: m.timeZone)?.secondsFromGMT(for: m.started) == 3600)
        #expect(m.durationMs == 2_076_000)
        #expect(m.app == Meeting.App(bundleId: "", name: "Slack"))
        #expect(m.speakers == [
            Meeting.Speaker(id: "s1", name: "Max Mitchell", isYou: false, talkMs: 7_000, nameSource: .user),
            Meeting.Speaker(id: "s2", name: "Them", isYou: false, talkMs: 2_055_000, nameSource: .user),
        ])
        #expect(m.paragraphs == [
            Meeting.Paragraph(speaker: "s1", startMs: 14_000, endMs: 21_000, text: "Morning. Shall we start with the deploy?"),
            Meeting.Paragraph(speaker: "s2", startMs: 21_000, endMs: 2_076_000, text: "Sure, give me a second to pull it up."),
        ])
        #expect(m.sharedBy == sender)
        #expect(!m.recordedHere)
        #expect(m.isDone && m.published)
        #expect(m.tracks.isEmpty && m.dictations.isEmpty && m.audio == nil)
    }

    @Test func aNameTheUserGaveThemselvesIsKept() throws {
        var meeting = MeetingFixtures.example
        meeting.speakers[0].name = "Max"
        meeting.speakers[0].nameSource = .user
        let m = try MeetingShare.meeting(from: MeetingShare.markdown(meeting, sender: sender))
        #expect(m.speakers.map(\.name) == ["Max", "Them"])
        #expect(m.sharedBy == sender)
    }

    @Test func quotesAndLineBreaksReadBackExactly() throws {
        var meeting = MeetingFixtures.example
        meeting.title = "He said \"ship it\"\nthen left \\ early"
        meeting.speakers[1].name = "Ann \"AJ\" Jones"
        let m = try MeetingShare.meeting(from: MeetingShare.markdown(meeting, sender: sender))
        #expect(m.title == meeting.title)
        #expect(m.speakers.map(\.name) == [sender, "Ann \"AJ\" Jones"])
        #expect(m.paragraphs.map(\.speaker) == ["s1", "s2"])
    }

    @Test func aParagraphPastAnHourReadsBack() throws {
        var meeting = MeetingFixtures.example
        meeting.durationMs = 3_700_000
        meeting.paragraphs[1].startMs = 3_661_000
        let m = try MeetingShare.meeting(from: MeetingShare.markdown(meeting, sender: sender))
        #expect(m.paragraphs.map(\.startMs) == [14_000, 3_661_000])
        #expect(m.durationMs == 3_700_000)
    }

    @Test func aLineThatOnlyLooksLikeAHeadingStaysWords() throws {
        var meeting = MeetingFixtures.example
        meeting.paragraphs[0].text = "Morning.\n**Bob** · 0:10"
        let m = try MeetingShare.meeting(from: MeetingShare.markdown(meeting, sender: sender))
        #expect(m.paragraphs.map(\.text) == ["Morning.\n**Bob** · 0:10", "Sure, give me a second to pull it up."])
    }

    @Test func windowsLineEndingsRead() throws {
        let text = MeetingShare.markdown(MeetingFixtures.example, sender: sender).replacingOccurrences(of: "\n", with: "\r\n")
        let m = try MeetingShare.meeting(from: text)
        #expect(m.paragraphs.map(\.text) == MeetingFixtures.example.paragraphs.map(\.text))
    }

    @Test func aForwardedMeetingNamesWhoForwardedIt() throws {
        let received = try MeetingShare.meeting(from: MeetingShare.markdown(MeetingFixtures.example, sender: sender))
        let forwarded = try MeetingShare.meeting(from: MeetingShare.markdown(received, sender: "Ellen"))
        #expect(forwarded.sharedBy == "Ellen")
        #expect(forwarded.speakers.map(\.name) == [sender, "Them"])
        #expect(forwarded.id == received.id)
    }

    @Test func plainMarkdownIsNotAMeeting() {
        #expect(throws: MeetingShare.ReadError.notAMeeting) {
            try MeetingShare.meeting(from: "# Notes\n\nJust text.\n")
        }
    }

    @Test func frontMatterWithoutAnIdIsNotAMeeting() {
        let text = MeetingShare.markdown(MeetingFixtures.example, sender: sender)
            .replacingOccurrences(of: "id: 9F2C0000-0000-0000-0000-000000000000\n", with: "")
        #expect(throws: MeetingShare.ReadError.notAMeeting) { try MeetingShare.meeting(from: text) }
    }

    @Test func aNewerFormatIsRefused() {
        let text = MeetingShare.markdown(MeetingFixtures.example, sender: sender).replacingOccurrences(of: "format: 1\n", with: "format: 2\n")
        #expect(throws: MeetingShare.ReadError.newerVersion) { try MeetingShare.meeting(from: text) }
    }
}
