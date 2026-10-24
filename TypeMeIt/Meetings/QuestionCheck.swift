import Foundation

/// The second look at a question the cheap rule let through: Claude Code on
/// its fastest model, with no tools, no settings files and no MCP servers,
/// answers one word. Its instructions carry the user's own past answers from
/// `QuestionLog`, so the questions they keep turning down stop being offered.
/// Measured: 3.8 to 5.5 s and about $0.003 a check on Haiku 4.5.
enum QuestionCheck {
    enum Verdict: String, Codable, Sendable {
        case question
        case notAQuestion
        /// Claude Code could not answer; the question is offered anyway.
        case failed
        /// Said to the app by name; not checked, and asked straight away.
        case addressed
    }

    static let model = "haiku"
    static let timeoutSeconds = 30.0
    /// The most of each kind of past answer the instructions carry.
    static let examplesPerAnswer = 15
    /// Sentences of the conversation before the question.
    static let contextSentences = 6

    static func instructions(wanted: [String], unwanted: [String]) -> String {
        var lines = ["Someone in a live meeting said the sentence below. Reply with exactly ask if it is a question the user would want an assistant with read access to the company's databases, analytics, code and docs to answer right now, or skip if it is small talk, a question for a person about their own views or plans, rhetorical, or a clarification. One word."]
        if !wanted.isEmpty { lines.append("Questions the user asked to have answered before:\n" + wanted.map { "- \($0)" }.joined(separator: "\n")) }
        if !unwanted.isEmpty { lines.append("Questions the user said not to ask:\n" + unwanted.map { "- \($0)" }.joined(separator: "\n")) }
        return lines.joined(separator: "\n\n")
    }

    static func prompt(question: String, context: [String]) -> String {
        (context.isEmpty ? "" : "Earlier in the meeting:\n" + context.joined(separator: "\n") + "\n\n") + "The sentence: \(question)"
    }

    static func verdict(from answer: ClaudeRun.Answer) -> Verdict {
        guard !answer.failed else { return .failed }
        switch answer.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() {
        case "ask": return .question
        case "skip": return .notAQuestion
        default: return .failed
        }
    }

    static func run(question: String, context: [String], wanted: [String], unwanted: [String]) async -> (Verdict, Double) {
        let arguments = ["-p", prompt(question: question, context: context),
                         "--output-format", "json",
                         "--model", model,
                         "--tools", "",
                         "--max-turns", "1",
                         "--setting-sources", "",
                         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                         "--disable-slash-commands",
                         "--system-prompt", instructions(wanted: wanted, unwanted: unwanted)]
        guard let run = ClaudeRun(arguments: arguments, input: "", folder: FileManager.default.homeDirectoryForCurrentUser,
                                  timeoutSeconds: timeoutSeconds) else { return (.failed, 0) }
        let answer = await run.answer()
        return (verdict(from: answer), answer.seconds)
    }
}
