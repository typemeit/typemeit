/// Apart from Meeting.swift, which the MCP tool compiles without
/// MeetingSummary.
extension Meeting {
    /// The paragraphs under their speakers' names, as the summary reads them.
    var turns: [MeetingSummary.Turn] {
        paragraphs.map { MeetingSummary.Turn(speaker: speakerName($0.speaker), text: $0.text) }
    }
}
