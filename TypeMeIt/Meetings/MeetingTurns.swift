/// Apart from Meeting.swift, which the MCP tool compiles without
/// MeetingSummary or MeetingFingerprint.
extension Meeting {
    /// Who spoke when, from the paragraphs' times and speakers alone. Nil
    /// for a meeting with no length.
    var fingerprint: MeetingFingerprint? {
        MeetingFingerprint(
            durationMs: durationMs,
            voices: speakers.map {
                MeetingFingerprint.Voice(id: $0.id, isYou: $0.isYou || $0.name == VoiceNames.youName, talkMs: $0.talkMs, name: Speaker.isPlaceholder($0.name) ? nil : $0.name)
            },
            turns: paragraphs.map { MeetingFingerprint.Turn(speaker: $0.speaker, startMs: $0.startMs, endMs: $0.endMs, aside: $0.aside == true) })
    }

    /// The paragraphs under their speakers' names, as the summary reads them.
    var turns: [MeetingSummary.Turn] {
        paragraphs.map { MeetingSummary.Turn(speaker: speakerName($0.speaker), text: $0.text) }
    }
}
