import Foundation
import Testing
@testable import TypeMeIt

struct ClaudeRunTests {
    @Test func theAnswerIsTheStreamsResultEvent() {
        let stream = """
            {"type":"system","subtype":"init"}
            {"type":"assistant","message":{"content":[]}}
            {"type":"result","result":"Sparkle.","is_error":false,"total_cost_usd":0.17}
            """
        #expect(ClaudeRun.parse(Data(stream.utf8), seconds: 15, exitStatus: 0)
            == ClaudeRun.Answer(text: "Sparkle.", seconds: 15, costUSD: 0.17, failed: false))
    }

    @Test func aFailedResultShowsItsErrors() {
        let stream = """
            {"type":"system","subtype":"init"}
            {"type":"result","subtype":"error_during_execution","is_error":true,"errors":["model not found"]}
            """
        #expect(ClaudeRun.parse(Data(stream.utf8), seconds: 4, exitStatus: 1)
            == ClaudeRun.Answer(text: "model not found", seconds: 4, costUSD: nil, failed: true))
    }

    @Test func aRunWithNoResultShowsStderr() {
        #expect(ClaudeRun.parse(Data(), errors: Data("error: unknown option '--x'\n".utf8), seconds: 1, exitStatus: 1)
            == ClaudeRun.Answer(text: "Claude Code stopped before answering, exit 1.\nerror: unknown option '--x'", seconds: 1, costUSD: nil, failed: true))
    }
}
