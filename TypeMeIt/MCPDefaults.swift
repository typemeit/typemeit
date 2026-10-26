/// The app's UserDefaults keys the MCP server also reads or writes.
enum MCPDefaults {
    /// Whether the MCP server answers at all. Named for meetings, which it
    /// once covered alone.
    static let enabledKey = "meetingsMCP"
    /// Tools the user switched off: left out of tools/list and refused if called.
    static let offToolsKey = "mcpOffTools"
    /// What every Claude Code run in the app is told on top of its own instructions.
    static let systemPromptKey = "askClaudeSystemPrompt"
}
