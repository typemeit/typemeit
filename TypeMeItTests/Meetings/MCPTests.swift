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

/// Hooks held in memory, where the real server keeps them in the app's UserDefaults.
private final class HookBox {
    var hooks: [MeetingHook] = []
}

private func memoryHooks(_ box: HookBox = HookBox()) -> MCPTools.HookStore {
    MCPTools.HookStore(read: { box.hooks }, write: { box.hooks = $0 })
}

private let releaseDictationID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!

/// Three dictations in `history.json` under `root`, written as the app's
/// `Store` writes them, out of time order: the edited one is the newest.
private func writeHistory(in root: URL) throws -> URL {
    let entries = [
        HistoryEntry(id: releaseDictationID, timestamp: iso("2026-02-01T09:00:00Z"), transcript: "ship the release on friday", postProcessRequested: false,
                     typed: "Ship the release on Friday.", appName: "Slack", windowTitle: "release-planning", dictionaryFixes: 0),
        HistoryEntry(timestamp: iso("2026-01-20T08:00:00Z"), transcript: "check the build", postProcessRequested: false,
                     appName: "Terminal", dictionaryFixes: 0),
        HistoryEntry(timestamp: iso("2026-02-03T10:00:00Z"), transcript: "draft the cafe menu", postProcessRequested: false,
                     typed: "Draft the café menu.", edited: "Draft the café menu today.", appName: "Notes", dictionaryFixes: 0),
    ]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let history = root.appendingPathComponent("history.json")
    try encoder.encode(entries).write(to: history)
    return history
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
        #expect(MCPTools.getMeeting(root: root, id: slackID.uuidString) == .success("\(Meeting.dataReminder)\n\n\(plain)"))
        #expect(MCPTools.searchMeetings(root: root, query: "Pelicans").isEmpty)
    }

    /// Settings explains each tool by name; a tool added to the server
    /// without one there would go unexplained.
    @Test func settingsNamesEveryTool() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reply = MCPServer.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, root: root, history: root.appendingPathComponent("history.json"), hooks: memoryHooks(), enabled: false)
        let served = decodeJSONValue(reply)?.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(served == MCPToolList.tools.map(\.name))
    }

    /// A tool switched off in settings is not listed, and calling it is refused.
    @Test func aToolSwitchedOffIsHiddenAndRefused() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("history.json")
        let list = MCPServer.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, root: root, history: history, hooks: memoryHooks(), enabled: true, off: ["add_hook"])
        let served = decodeJSONValue(list)?.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(served == MCPToolList.tools.map(\.name).filter { $0 != "add_hook" })
        let call = MCPServer.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add_hook","arguments":{"name":"n","prompt":"p"}}}"#,
                                    root: root, history: history, hooks: memoryHooks(), enabled: true, off: ["add_hook"])
        let result = decodeJSONValue(call)?.objectValue?["result"]?.objectValue
        #expect(result?["isError"] == .bool(true))
        #expect(result?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue == MCPTools.toolOffMessage)
    }

    @Test func theSystemPromptIsReadAndReplaced() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("history.json")
        nonisolated(unsafe) var stored = "Read origin/main."
        let prompt = MCPTools.PromptStore(read: { stored }, write: { stored = $0 })
        func text(_ line: String) -> String? {
            decodeJSONValue(MCPServer.handle(line, root: root, history: history, hooks: memoryHooks(), enabled: true, systemPrompt: prompt))?
                .objectValue?["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        }
        #expect(text(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_system_prompt"}}"#) == "Read origin/main.")
        #expect(text(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_system_prompt","arguments":{"prompt":"  Be brief.\n"}}}"#) == "system prompt saved")
        #expect(stored == "Be brief.")
    }

    @Test func pingRequestGetsAMatchingResponse() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reply = MCPServer.handle(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, root: root, history: root.appendingPathComponent("history.json"), hooks: memoryHooks(), enabled: false)
        #expect(decodeJSONValue(reply) == .object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "result": .object([:]),
        ]))
    }

    @Test(arguments: [
        // What current MCP clients send.
        ("2025-11-25", "2025-11-25"),
        ("2024-11-05", "2024-11-05"),
        // No initialize handshake in this revision, so it is not echoed.
        ("2026-07-28", "2025-11-25"),
    ])
    func initializeAnswersWithAVersionItSpeaks(requested: String, answered: String) throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reply = MCPServer.handle(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"\#(requested)"}}"#, root: root, history: root.appendingPathComponent("history.json"), hooks: memoryHooks(), enabled: false)
        #expect(decodeJSONValue(reply) == .object([
            "jsonrpc": .string("2.0"),
            "id": .number(0),
            "result": .object([
                "protocolVersion": .string(answered),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("typemeit-mcp"), "version": .string("1.0")]),
            ]),
        ]))
    }

    @Test func aNotificationGetsNoReply() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MCPServer.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, root: root, history: root.appendingPathComponent("history.json"), hooks: memoryHooks(), enabled: false) == nil)
    }

    @Test func anUnknownMethodIsMethodNotFound() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reply = MCPServer.handle(#"{"jsonrpc":"2.0","id":"a","method":"nonsense"}"#, root: root, history: root.appendingPathComponent("history.json"), hooks: memoryHooks(), enabled: false)
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
        #expect(result == .success("\(Meeting.dataReminder)\n\n\(raw)"))
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

        #expect(part1 == .success("\(Meeting.dataReminder)\n\npart 1 of 2, 1 more part(s) remain\n\n\(expectedFirst)"))
        #expect(part2 == .success("\(Meeting.dataReminder)\n\npart 2 of 2, 0 more part(s) remain\n\n\(expectedSecond)"))
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
        shared.sharedBy = "Edie"
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
            ("list_dictations", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_dictations","arguments":{}}}"#),
            ("search_dictations", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_dictations","arguments":{"query":"x"}}}"#),
            ("list_hooks", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_hooks","arguments":{}}}"#),
            ("add_hook", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_hook","arguments":{"name":"x","prompt":"x"}}}"#),
            ("update_hook", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_hook","arguments":{"id":"x"}}}"#),
            ("remove_hook", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"remove_hook","arguments":{"id":"x"}}}"#),
        ]
        _ = try writeHistory(in: root)
        for (name, line) in calls {
            let reply = MCPServer.handle(line, root: root, history: root.appendingPathComponent("history.json"), hooks: memoryHooks(), enabled: false)
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

    // MARK: dictations

    @Test func listDictationsIsNewestFirstAndFiltersByAppAndDate() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try writeHistory(in: root)
        #expect(MCPTools.listDictations(history: history).map(\.text) == ["Draft the café menu today.", "Ship the release on Friday.", "check the build"])
        #expect(MCPTools.listDictations(history: history, app: "slack").map(\.text) == ["Ship the release on Friday."])
        #expect(MCPTools.listDictations(history: history, from: iso("2026-02-02T00:00:00Z")).map(\.text) == ["Draft the café menu today."])
        #expect(MCPTools.listDictations(history: history, limit: 1).map(\.text) == ["Draft the café menu today."])
    }

    @Test func aDictationSummaryCarriesItsAppAndWindow() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try writeHistory(in: root)
        #expect(MCPTools.listDictations(history: history, app: "Slack") == [MCPTools.DictationSummary(
            id: releaseDictationID.uuidString, time: iso("2026-02-01T09:00:00Z"), app: "Slack", window: "release-planning",
            text: "Ship the release on Friday.")])
    }

    @Test func searchDictationsMatchesTheShownTextIgnoringCaseAndAccents() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try writeHistory(in: root)
        #expect(MCPTools.searchDictations(history: history, query: "CAFE MENU TODAY").map(\.text) == ["Draft the café menu today."])
        #expect(MCPTools.searchDictations(history: history, query: "draft the cafe menu.").isEmpty)
    }

    @Test func noHistoryFileMeansNoDictations() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MCPTools.listDictations(history: root.appendingPathComponent("history.json")).isEmpty)
    }

    // MARK: hooks

    @Test func aHookAnAssistantAddsArrivesSwitchedOff() throws {
        let box = HookBox()
        let added = try MCPTools.addHook(memoryHooks(box), name: " action items ", prompt: "List the action items.").get()
        #expect(box.hooks == [MeetingHook(id: added.id, name: "action items", prompt: "List the action items.", on: false)])
    }

    @Test func changingAHookSwitchesItOff() throws {
        let box = HookBox()
        box.hooks = [MeetingHook(name: "summary", prompt: "Summarise it.", on: true)]
        let changed = try MCPTools.updateHook(memoryHooks(box), id: box.hooks[0].id.uuidString, name: nil, prompt: "Summarise it in three lines.").get()
        #expect(box.hooks == [MeetingHook(id: changed.id, name: "summary", prompt: "Summarise it in three lines.", on: false)])
    }

    @Test func removingAHookLeavesTheOthers() throws {
        let box = HookBox()
        let kept = MeetingHook(name: "summary", prompt: "Summarise it.")
        let dropped = MeetingHook(name: "tickets", prompt: "File tickets.")
        box.hooks = [kept, dropped]
        #expect(try MCPTools.removeHook(memoryHooks(box), id: dropped.id.uuidString).get() == dropped)
        #expect(box.hooks == [kept])
    }

    @Test func aHookWriteWithABadIdOrNameChangesNothing() {
        let box = HookBox()
        box.hooks = [MeetingHook(name: "summary", prompt: "Summarise it.")]
        let before = box.hooks
        #expect(MCPTools.updateHook(memoryHooks(box), id: "../hooks", name: "x", prompt: nil) == .failure(.noHook))
        #expect(MCPTools.removeHook(memoryHooks(box), id: UUID().uuidString) == .failure(.noHook))
        #expect(MCPTools.addHook(memoryHooks(box), name: "  ", prompt: "x") == .failure(.badArgument("add_hook requires a name")))
        #expect(MCPTools.updateHook(memoryHooks(box), id: before[0].id.uuidString, name: " ", prompt: nil) == .failure(.badArgument("a hook's name can't be empty")))
        #expect(box.hooks == before)
    }

    @Test func addHookOverTheProtocolSaysItIsOff() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = HookBox()
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_hook","arguments":{"name":"summary","prompt":"Summarise it."}}}"#
        let reply = MCPServer.handle(line, root: root, history: root.appendingPathComponent("history.json"), hooks: memoryHooks(box), enabled: true)
        let hook = try #require(box.hooks.first)
        #expect(decodeJSONValue(reply) == .object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "result": .object([
                "content": .array([.object(["type": .string("text"), "text": .string(MCPTools.renderWrittenHook(hook))])]),
                "isError": .bool(false),
            ]),
        ]))
        #expect(hook.on == false)
    }
}
