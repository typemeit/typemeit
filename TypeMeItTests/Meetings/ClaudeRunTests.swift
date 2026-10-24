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

    @Test func aSandboxedBuildHasNoClaudeToRun() {
        let installed = URL(fileURLWithPath: "/usr/local/bin/claude")
        #expect(ClaudeRun.availableExecutable(sandboxed: true, installed: installed) == nil)
        #expect(ClaudeRun.availableExecutable(sandboxed: false, installed: installed) == installed)
        #expect(ClaudeRun.availableExecutable(sandboxed: false, installed: nil) == nil)
    }

    @Test func aCommandWithNoClaudeDoesNotStart() {
        #expect(ClaudeRun.command(["mcp", "list"], timeoutSeconds: 5, executable: nil)?.process == nil)
    }

    @Test func aCommandGetsItsArgumentsAndInputAndHandsBackItsOutput() throws {
        let command = try #require(ClaudeRun.command(["-c", "read line; echo \"$line $0\"", "done"], timeoutSeconds: 5,
                                                     executable: URL(fileURLWithPath: "/bin/sh")))
        command.input.write(Data("asked\n".utf8))
        try command.input.close()
        let output = command.output.readDataToEndOfFile()
        command.process.waitUntilExit()
        #expect(String(decoding: output, as: UTF8.self) == "asked done\n")
        #expect(command.process.currentDirectoryURL == FileManager.default.homeDirectoryForCurrentUser)
        #expect(command.process.environment == ClaudeRun.environment)
    }
}
