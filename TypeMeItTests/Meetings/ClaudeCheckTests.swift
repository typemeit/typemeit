import Testing
@testable import TypeMeIt

struct ClaudeCheckTests {
    private static let code = "C0DE"
    private static let main = ClaudeRun.Answer(text: code, seconds: 3, costUSD: nil, failed: false,
                                               setup: ClaudeRun.Setup(version: "2.1.281", permissionMode: "auto", model: "claude-sonnet-5", tools: ["Read"]))
    private static let question = ClaudeRun.Answer(text: "Are we keeping the free tier?", seconds: 1, costUSD: nil, failed: false,
                                                   setup: ClaudeRun.Setup(version: "2.1.281", permissionMode: "default", model: "claude-haiku-4-5", thinkingTokens: 0))

    private static func problems(main: ClaudeRun.Answer = main, question: ClaudeRun.Answer = question) -> [String] {
        ClaudeCheck.problems(main: main, code: code, permissionMode: "auto", question: question)
    }

    @Test func runsAsAskedHaveNoProblems() {
        #expect(Self.problems() == [])
    }

    @Test func aRunThatFailedOutrightLeavesItsErrorToItsOutput() {
        #expect(Self.problems(main: ClaudeRun.Answer(text: "Log in to Claude Code: run claude in a terminal and type /login.", seconds: 1, costUSD: nil, failed: true)) == [])
    }

    @Test func ignoredFlagsOnTheAskRunShow() {
        let main = ClaudeRun.Answer(text: "OK", seconds: 3, costUSD: nil, failed: false,
                                    setup: ClaudeRun.Setup(permissionMode: "default", tools: ["Read", ClaudeRun.disallowedTool]))
        #expect(Self.problems(main: main) == [
            "ran in default permission mode, not auto",
            "Agent tool not removed",
            "system prompt not applied",
        ])
    }

    @Test func aQuestionRunThatIsNotBareShows() {
        let question = ClaudeRun.Answer(text: "Are we keeping the free tier?", seconds: 5, costUSD: nil, failed: false,
                                        setup: ClaudeRun.Setup(model: "claude-sonnet-5", tools: ["Read"], mcpServers: ["typemeit", "linear"], thinkingTokens: 512))
        #expect(Self.problems(question: question) == [
            "finding the question: has 1 tool",
            "finding the question: started 2 mcp servers",
            "finding the question: ran on claude-sonnet-5, not haiku",
            "finding the question: thinking is back on",
        ])
    }

    @Test func thinkingThatIsNoLongerReportedShows() {
        let question = ClaudeRun.Answer(text: "Are we keeping the free tier?", seconds: 1, costUSD: nil, failed: false,
                                        setup: ClaudeRun.Setup(model: "claude-haiku-4-5"))
        #expect(Self.problems(question: question) == ["finding the question: thinking not reported"])
    }

    @Test func runsWithNoStartEventShow() {
        let bare = ClaudeRun.Answer(text: Self.code, seconds: 1, costUSD: nil, failed: false)
        #expect(Self.problems(main: bare, question: bare) == ["no start event", "finding the question: no start event"])
    }

    @Test func aWorkingClaudeCodeShowsItsVersion() {
        #expect(ClaudeCheck.caption(.passed(version: "2.1.281"), lastPassed: "2.1.281") == "2.1.281 · working")
    }

    @Test func aNewerClaudeCodeThatRunsDifferentlyIsNotSupported() {
        #expect(ClaudeCheck.caption(.failed(version: "2.1.290", problems: ["system prompt not applied"], error: nil), lastPassed: "2.1.281")
            == "2.1.290 · not supported yet")
    }

    @Test func theVersionThatPassedFailingPointsAtTheSettings() {
        #expect(ClaudeCheck.caption(.failed(version: "2.1.281", problems: ["ran in default permission mode, not auto"], error: nil), lastPassed: "2.1.281")
            == "2.1.281 · doesn't work with these settings")
    }

    @Test func aRunThatFailedOutrightShowsItsOwnErrorsFirstLine() {
        #expect(ClaudeCheck.caption(.failed(version: "2.1.281", problems: [], error: "Log in to Claude Code: run claude in a terminal and type /login.\nexit 1"), lastPassed: nil)
            == "Log in to Claude Code: run claude in a terminal and type /login")
    }
}
