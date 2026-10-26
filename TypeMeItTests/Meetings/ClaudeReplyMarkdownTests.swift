import Testing
@testable import TypeMeIt

struct ClaudeReplyMarkdownTests {
    @Test func aFencedAsciiTableBecomesAMarkdownTable() {
        let reply = "Calls by surface:\n\n```\n+--------------+-------+\n| surface      | calls |\n+--------------+-------+\n| call log     |    41 |\n| inquiry feed |    17 |\n+--------------+-------+\n```\n\nMost were the call log."
        #expect(ClaudeReplyMarkdown.markdown(reply) == "Calls by surface:\n\n| surface | calls |\n| --- | --- |\n| call log | 41 |\n| inquiry feed | 17 |\n\n\nMost were the call log.")
    }

    @Test func anUnfencedAsciiTableBecomesAMarkdownTable() {
        let reply = "Calls:\n+---+---+\n| a | b |\n+---+---+\n| 1 | 2 |\n+---+---+\nThat is all."
        #expect(ClaudeReplyMarkdown.markdown(reply) == "Calls:\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nThat is all.")
    }

    @Test func aBoxDrawnTableBecomesAMarkdownTable() {
        let reply = "┌────┬─────┐\n│ who│ task│\n├────┼─────┤\n│ Sam│ ship│\n└────┴─────┘"
        #expect(ClaudeReplyMarkdown.markdown(reply) == "| who | task |\n| --- | --- |\n| Sam | ship |\n")
    }

    @Test func aTableWithNoHeaderRuleTakesItsFirstRowAsHeader() {
        let reply = "+---+---+\n| a | b |\n| 1 | 2 |\n+---+---+"
        #expect(ClaudeReplyMarkdown.markdown(reply) == "| a | b |\n| --- | --- |\n| 1 | 2 |\n")
    }

    @Test func aHeaderOverTwoLinesJoinsPerColumn() {
        let table = ClaudeReplyMarkdown.table(["+-------+------+", "| calls | wait |", "| today | (s)  |", "+-------+------+", "| 41    | 12   |", "+-------+------+"])
        #expect(table == ["| calls today | wait (s) |", "| --- | --- |", "| 41 | 12 |"])
    }

    @Test func aRowWhoseWallsMissTheRuleIsNotATable() {
        #expect(ClaudeReplyMarkdown.table(["+---+---+", "| a |  b |", "+---+---+"]) == nil)
    }

    @Test func aDiagramStaysFenced() {
        let reply = "```\n  [app] --> [server]\n     |\n  [db]\n```"
        #expect(ClaudeReplyMarkdown.markdown(reply) == reply)
    }

    @Test func anUnfencedDiagramIsFenced() {
        #expect(ClaudeReplyMarkdown.markdown("┌─┐\n└─┘") == "```\n┌─┐\n└─┘\n```")
    }

    @Test func aMarkdownTableStaysATable() {
        let reply = "Owners:\n| task | who |\n|------|-----|\n| scope | Sam |\n\nThat is all."
        #expect(ClaudeReplyMarkdown.markdown(reply) == "Owners:\n\n| task | who |\n|------|-----|\n| scope | Sam |\n\nThat is all.")
    }

    @Test func anUnclosedFenceIsLeftAsItIs() {
        let reply = "Here:\n```\n| a | b |\n┌─┐"
        #expect(ClaudeReplyMarkdown.markdown(reply) == reply)
    }

    @Test func proseIsLeftAlone() {
        let reply = "Kick-off is at 20:45.\n\n- one\n- two"
        #expect(ClaudeReplyMarkdown.markdown(reply) == reply)
    }
}
