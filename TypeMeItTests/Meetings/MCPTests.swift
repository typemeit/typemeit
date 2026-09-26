import Foundation
import Testing
@testable import TypeMeIt

private func tempRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func iso(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

/// A minimally-filled `Meeting`: the fields `MCPTools` never reads (audio,
/// dictations, transcription, tracks, echo) are fixed placeholders so every
/// fixture meeting only has to spell out what the test cares about.
private func makeMeeting(
    id: UUID, kind: Meeting.Kind, started: Date, durationMs: Int,
    app: Meeting.App?, title: String, speakers: [Meeting.Speaker],
    paragraphs: [Meeting.Paragraph]
) -> Meeting {
    Meeting(
        id: id, kind: kind, started: started, timeZone: "UTC",
        ended: started.addingTimeInterval(Double(durationMs) / 1000),
        durationMs: durationMs, recordedMs: durationMs, firstHostTime: nil,
        app: app, title: title, titleSource: .app, published: true,
        tracks: [], audio: nil, echo: .notMeasured, bothSilentMs: 0,
        dictations: [], speakers: speakers,
        transcription: Meeting.Transcription(state: .done, error: nil, asr: "test", diarizer: nil, tookMs: 0, done: [:]),
        paragraphs: paragraphs)
}

private let slackID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let zoomID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let roomID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

private func slackMeeting() -> Meeting {
    makeMeeting(
        id: slackID, kind: .call, started: iso("2026-01-10T09:00:00Z"), durationMs: 2_400_000,
        app: Meeting.App(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"), title: "Slack",
        speakers: [
            Meeting.Speaker(id: "you", name: "You", isYou: true, talkMs: 1_000_000),
            Meeting.Speaker(id: "them", name: "Them", isYou: false, talkMs: 1_400_000),
        ],
        paragraphs: [
            Meeting.Paragraph(speaker: "you", startMs: 0, endMs: 5000, text: "Morning, how are you today?"),
            Meeting.Paragraph(speaker: "them", startMs: 5000, endMs: 10000, text: "Let's deploy the new build after lunch."),
        ])
}

private func zoomMeeting() -> Meeting {
    makeMeeting(
        id: zoomID, kind: .call, started: iso("2026-01-15T09:00:00Z"), durationMs: 1_500_000,
        app: Meeting.App(bundleId: "us.zoom.xos", name: "Zoom"), title: "Zoom",
        speakers: [
            Meeting.Speaker(id: "you", name: "You", isYou: true, talkMs: 700_000),
            Meeting.Speaker(id: "ana", name: "Ana", isYou: false, talkMs: 800_000),
        ],
        paragraphs: [
            Meeting.Paragraph(speaker: "you", startMs: 0, endMs: 4000, text: "Quick check-in before we deploy anything."),
            Meeting.Paragraph(speaker: "ana", startMs: 4000, endMs: 9000, text: "Sounds good, ship it."),
        ])
}

/// Plain ASCII throughout, so its rendered transcript's UTF-8 byte offsets
/// line up one-for-one with `String` character offsets — the test computes
/// the expected split by slicing at a character index.
private func roomMeeting(paragraphCount: Int) -> Meeting {
    let paragraphs = (0 ..< paragraphCount).map { index in
        Meeting.Paragraph(
            speaker: index.isMultiple(of: 2) ? "you" : "s1",
            startMs: index * 2000, endMs: index * 2000 + 1500,
            text: "This is paragraph number \(index) about the migration plan, covering steps, risks and owners.")
    }
    return makeMeeting(
        id: roomID, kind: .room, started: iso("2026-02-01T09:00:00Z"), durationMs: 5_400_000,
        app: nil, title: "Room",
        speakers: [
            Meeting.Speaker(id: "you", name: "You", isYou: true, talkMs: 2_000_000),
            Meeting.Speaker(id: "s1", name: "Speaker 1", isYou: false, talkMs: 2_000_000),
        ],
        paragraphs: paragraphs)
}

/// Writes the three meetings above under a fresh temporary root, plus a
/// fourth meeting inside `.in-progress` that a correct scan never surfaces.
private func writeFixture() throws -> URL {
    let root = tempRoot()
    try MeetingFolder.write(slackMeeting(), to: root.appendingPathComponent("Slack Meeting", isDirectory: true))
    try MeetingFolder.write(zoomMeeting(), to: root.appendingPathComponent("Zoom Meeting", isDirectory: true))
    try MeetingFolder.write(roomMeeting(paragraphCount: 300), to: root.appendingPathComponent("Room Meeting", isDirectory: true))

    let staged = makeMeeting(
        id: UUID(), kind: .call, started: iso("2026-03-01T09:00:00Z"), durationMs: 60_000,
        app: nil, title: "Staged", speakers: [], paragraphs: [])
    try MeetingFolder.write(staged, to: root.appendingPathComponent(".in-progress/staged-uuid", isDirectory: true))

    return root
}

/// Splits `text` where `get_meeting` would: at `maxBytes` UTF-8 bytes, on a
/// `Character` boundary. Written independently of `MCPTools`'s own chunker
/// so the test pins down the contract (fits the budget, cuts on a character,
/// never a multi-byte scalar like "·" mid-way) rather than mirroring its code.
private func splitAtByteBudget(_ text: String, maxBytes: Int) -> (first: String, rest: String) {
    var bytes = 0
    var cut = text.endIndex
    for index in text.indices {
        let characterBytes = String(text[index]).utf8.count
        if bytes + characterBytes > maxBytes {
            cut = index
            break
        }
        bytes += characterBytes
    }
    return (String(text[..<cut]), String(text[cut...]))
}

private func decodeJSONValue(_ line: String?) -> JSONValue? {
    guard let line, let data = line.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}

struct MCPTests {
    // MARK: framing

    /// The page's summary stays on the page: the transcript the MCP
    /// returns is the one without it, and its words are not searchable.
    @Test func theSummaryIsNeverServed() throws {
        let root = tempRoot()
        var meeting = slackMeeting()
        let plain = TranscriptRender.markdown(meeting)
        meeting.summary = "Pelicans migrate in November."
        try MeetingFolder.write(meeting, to: root.appendingPathComponent("Slack Meeting", isDirectory: true))

        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MCPTools.getMeeting(root: root, id: slackID.uuidString) == .success("\(MCPTools.dataReminder)\n\n\(plain)"))
        #expect(MCPTools.searchMeetings(root: root, query: "Pelicans").isEmpty)
    }

    @Test func pingRequestGetsAMatchingResponse() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reply = MCPServer.handle(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, root: root, enabled: false)
        #expect(decodeJSONValue(reply) == .object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "result": .object([:]),
        ]))
    }

    @Test func aNotificationGetsNoReply() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MCPServer.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, root: root, enabled: false) == nil)
    }

    @Test func anUnknownMethodIsMethodNotFound() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reply = MCPServer.handle(#"{"jsonrpc":"2.0","id":"a","method":"nonsense"}"#, root: root, enabled: false)
        #expect(decodeJSONValue(reply) == .object([
            "jsonrpc": .string("2.0"),
            "id": .string("a"),
            "error": .object(["code": .number(-32601), "message": .string("unknown method: nonsense")]),
        ]))
    }

    // MARK: list_meetings

    @Test func listMeetingsReturnsEveryPublishedMeetingNewestFirstAndSkipsStaging() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = MCPTools.listMeetings(root: root).map(\.id)
        #expect(ids == [roomID.uuidString, zoomID.uuidString, slackID.uuidString])
    }

    @Test func listMeetingsFiltersByDate() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = MCPTools.listMeetings(root: root, from: iso("2026-01-12T00:00:00Z"), to: iso("2026-01-31T23:59:59Z")).map(\.id)
        #expect(ids == [zoomID.uuidString])
    }

    @Test func listMeetingsFiltersByApp() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = MCPTools.listMeetings(root: root, app: "zoom").map(\.id)
        #expect(ids == [zoomID.uuidString])
    }

    @Test func listMeetingsFiltersBySpeaker() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = MCPTools.listMeetings(root: root, speaker: "ana").map(\.id)
        #expect(ids == [zoomID.uuidString])
    }

    @Test func listMeetingsFiltersByKind() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = MCPTools.listMeetings(root: root, kind: "room").map(\.id)
        #expect(ids == [roomID.uuidString])
    }

    @Test func listMeetingsSummaryMatchesTheMeeting() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let summaries = MCPTools.listMeetings(root: root, app: "slack")
        #expect(summaries == [
            MCPTools.MeetingSummary(
                id: slackID.uuidString, title: "Slack", started: iso("2026-01-10T09:00:00Z"),
                duration: "40m", kind: "call", app: "Slack", speakers: ["You", "Them"], folder: "Slack Meeting"),
        ])
    }

    // MARK: get_meeting

    @Test func getMeetingReturnsTheWholeTranscriptWhenItFitsTheBudget() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = try String(contentsOf: root.appendingPathComponent("Slack Meeting/transcript.md"), encoding: .utf8)
        let result = MCPTools.getMeeting(root: root, id: slackID.uuidString)
        #expect(result == .success("\(MCPTools.dataReminder)\n\n\(raw)"))
    }

    @Test func getMeetingSplitsAndReassemblesALargeTranscript() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = try String(contentsOf: root.appendingPathComponent("Room Meeting/transcript.md"), encoding: .utf8)
        #expect(raw.utf8.count > MCPTools.meetingMCPBudgetBytes)

        let (expectedFirst, expectedSecond) = splitAtByteBudget(raw, maxBytes: MCPTools.meetingMCPBudgetBytes)

        let part1 = MCPTools.getMeeting(root: root, id: roomID.uuidString, part: 1)
        let part2 = MCPTools.getMeeting(root: root, id: roomID.uuidString, part: 2)
        let part3 = MCPTools.getMeeting(root: root, id: roomID.uuidString, part: 3)

        #expect(part1 == .success("\(MCPTools.dataReminder)\n\npart 1 of 2, 1 more part(s) remain\n\n\(expectedFirst)"))
        #expect(part2 == .success("\(MCPTools.dataReminder)\n\npart 2 of 2, 0 more part(s) remain\n\n\(expectedSecond)"))
        #expect(part3 == .failure(.badArgument("meeting has only 2 part(s)")))
    }

    @Test func getMeetingWithAPathTraversalIDIsRefused() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MCPTools.getMeeting(root: root, id: "../../../../etc/passwd") == .failure(.notFound))
    }

    // MARK: search_meetings

    @Test func searchMeetingsFindsAWordAcrossTwoMeetingsWithTheRightSpeakerAndTimestamp() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let hits = MCPTools.searchMeetings(root: root, query: "deploy")
        #expect(hits == [
            MCPTools.SearchHit(
                meetingId: zoomID.uuidString, meetingTitle: "Zoom", speaker: "You",
                timestamp: "0:00", paragraph: "Quick check-in before we deploy anything."),
            MCPTools.SearchHit(
                meetingId: slackID.uuidString, meetingTitle: "Slack", speaker: "Them",
                timestamp: "0:05", paragraph: "Let's deploy the new build after lunch."),
        ])
    }

    // MARK: meeting_stats

    @Test func meetingStatsCountsDurationAndTalkTimeOverARange() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stats = MCPTools.meetingStats(root: root, from: iso("2026-01-01T00:00:00Z"), to: iso("2026-01-31T23:59:59Z"))
        #expect(stats == MCPTools.Stats(
            count: 2, totalDuration: "1h5m",
            talkBySpeaker: ["You": "28m", "Them": "23m", "Ana": "13m"]))
    }

    @Test func meetingStatsLeavesOutAMeetingSomeoneShared() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var shared = slackMeeting()
        shared.id = UUID()
        shared.sharedBy = "Ellen"
        try MeetingFolder.write(shared, to: root.appendingPathComponent("Shared Meeting", isDirectory: true))
        let stats = MCPTools.meetingStats(root: root, from: iso("2026-01-01T00:00:00Z"), to: iso("2026-01-31T23:59:59Z"))
        #expect(stats == MCPTools.Stats(
            count: 2, totalDuration: "1h5m",
            talkBySpeaker: ["You": "28m", "Them": "23m", "Ana": "13m"]))
    }

    // MARK: the switch

    @Test func everyToolReturnsTheSameErrorWhenTheSwitchIsOff() throws {
        let root = try writeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls: [(String, String)] = [
            ("list_meetings", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#),
            ("get_meeting", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":"x"}}}"#),
            ("search_meetings", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"x"}}}"#),
            ("meeting_stats", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"meeting_stats","arguments":{}}}"#),
        ]
        for (name, line) in calls {
            let reply = MCPServer.handle(line, root: root, enabled: false)
            #expect(
                decodeJSONValue(reply) == .object([
                    "jsonrpc": .string("2.0"),
                    "id": .number(1),
                    "result": .object([
                        "content": .array([.object(["type": .string("text"), "text": .string(MCPTools.disabledMessage)])]),
                        "isError": .bool(true),
                    ]),
                ]),
                "\(name) did not return the disabled error")
        }
    }
}
