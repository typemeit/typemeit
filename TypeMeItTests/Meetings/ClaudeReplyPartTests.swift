import Testing
@testable import TypeMeIt

struct ClaudeReplyPartTests {
    @Test func aFencedBlockIsADrawingWithoutItsFences() {
        let reply = "Calls by surface:\n\n```\n+----+\n| a  |\n+----+\n```\n\nMost were a."
        #expect(ClaudeReplyPart.parts(of: reply) == [
            .prose("Calls by surface:"),
            .drawing("+----+\n| a  |\n+----+"),
            .prose("Most were a."),
        ])
    }

    @Test func aFencedBlockKeepsItsIndentAndBlankLines() {
        #expect(ClaudeReplyPart.parts(of: "```text\n  [app]\n\n    |\n  [server]\n```")
            == [.drawing("  [app]\n\n    |\n  [server]")])
    }

    @Test func tableLinesOutsideAFenceAreADrawing() {
        let reply = "Owners:\n| task | who |\n|------|-----|\n| scope | Sam |\nThat is all."
        #expect(ClaudeReplyPart.parts(of: reply) == [
            .prose("Owners:"),
            .drawing("| task | who |\n|------|-----|\n| scope | Sam |"),
            .prose("That is all."),
        ])
    }

    @Test func boxDrawingLinesAreADrawing() {
        #expect(ClaudeReplyPart.parts(of: "┌─┐\n└─┘") == [.drawing("┌─┐\n└─┘")])
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        #expect(ClaudeReplyPart.parts(of: "Here:\n```\na  b\nc  d") == [.prose("Here:"), .drawing("a  b\nc  d")])
    }

    @Test func proseIsOnePart() {
        #expect(ClaudeReplyPart.parts(of: "Kick-off is at 20:45.\n\n- one\n- two") == [.prose("Kick-off is at 20:45.\n\n- one\n- two")])
    }
}
