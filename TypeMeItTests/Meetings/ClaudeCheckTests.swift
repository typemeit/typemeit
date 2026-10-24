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
            "question run has 1 tool",
            "question run started 2 mcp servers",
            "question run on claude-sonnet-5, not haiku",
            "question run thought for 512 tokens",
        ])
    }

    @Test func thinkingThatIsNoLongerReportedShows() {
        let question = ClaudeRun.Answer(text: "Are we keeping the free tier?", seconds: 1, costUSD: nil, failed: false,
                                        setup: ClaudeRun.Setup(model: "claude-haiku-4-5"))
        #expect(Self.problems(question: question) == ["question run's thinking not reported"])
    }

    @Test func runsWithNoStartEventShow() {
        let bare = ClaudeRun.Answer(text: Self.code, seconds: 1, costUSD: nil, failed: false)
        #expect(Self.problems(main: bare, question: bare) == ["no start event", "question run: no start event"])
    }
}
