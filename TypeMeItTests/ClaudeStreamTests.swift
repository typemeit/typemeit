import Testing
@testable import TypeMeIt

struct ClaudeStreamTests {
    @Test func theSessionStartSaysTheModelAndSession() {
        let event = #"{"type":"system","subtype":"init","model":"claude-sonnet-5","session_id":"7f419a76-60e8-4b4d-949d-512738fb52c5"}"#
        #expect(ClaudeStream.event(for: event) == .started(model: "claude-sonnet-5", sessionID: "7f419a76-60e8-4b4d-949d-512738fb52c5"))
    }

    @Test func aToolCallShowsItsServerToolAndInputValues() {
        let event = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__typemeit__search_meetings","input":{"query":"deploy"}}]}}"#
        #expect(ClaudeStream.event(for: event) == .lines([.call("typemeit search_meetings deploy", result: nil)]))
    }

    @Test func claudeLoadingItsToolsShowsNothing() {
        let call = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ToolSearch","input":{"query":"select:x"}}]}}"#
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"tool_reference","tool_name":"x"}]}]}}"#
        #expect(ClaudeStream.event(for: call) == nil)
        #expect(ClaudeStream.event(for: result) == nil)
    }

    @Test func aToolResultIsOneShortLine() {
        let long = String(repeating: "a", count: ClaudeStream.summaryLength + 20)
        let event = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"first\nsecond"},{"type":"tool_result","content":[{"type":"text","text":"\#(long)"}]}]}}"#
        #expect(ClaudeStream.event(for: event) == .results(["first second", String(repeating: "a", count: ClaudeStream.summaryLength) + "…"]))
    }

    @Test func aMeetingResultLeavesOutTheDataReminder() {
        let event = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"\#(Meeting.dataReminder)\n\ntitle: Standup"}]}}"#
        #expect(ClaudeStream.event(for: event) == .results(["title: Standup"]))
    }

    @Test func wordsAndTheEndShow() {
        #expect(ClaudeStream.event(for: #"{"type":"assistant","message":{"content":[{"type":"text","text":"  Kick-off is at 20:45.\n"}]}}"#) == .lines([.text("Kick-off is at 20:45.")]))
        #expect(ClaudeStream.event(for: #"{"type":"result","duration_ms":13138,"is_error":false}"#) == .ended(seconds: 13, failed: false))
    }

    @Test func otherEventsShowNothing() {
        #expect(ClaudeStream.event(for: #"{"type":"rate_limit_event"}"#) == nil)
        #expect(ClaudeStream.event(for: "not json") == nil)
    }
}
