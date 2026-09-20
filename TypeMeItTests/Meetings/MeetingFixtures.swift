import Foundation
@testable import TypeMeIt

/// The example meeting from docs/meetings.md 7.9, as a Swift literal so
/// codable and render tests share one source of truth.
enum MeetingFixtures {
    static let example = Meeting(
        id: UUID(uuidString: "9F2C0000-0000-0000-0000-000000000000")!,
        kind: .call,
        started: Date(timeIntervalSince1970: 1_789_824_612), // 2026-09-19T13:30:12Z
        timeZone: "Europe/London",
        ended: Date(timeIntervalSince1970: 1_789_826_688), // 2026-09-19T14:04:48Z
        durationMs: 2_076_000,
        recordedMs: 2_014_000,
        firstHostTime: 123_456_789_012,
        app: Meeting.App(bundleId: "com.tinyspeck.slackmacgap", name: "Slack"),
        title: "Slack",
        titleSource: .app,
        published: true,
        tracks: [
            Meeting.Track(
                role: .mic, file: "mic.m4a", frames: 2_076_000 * Meeting.framesPerMs,
                gaps: [Meeting.Span(startMs: 1_840_000, endMs: 1_902_000)]),
            Meeting.Track(
                role: .others, file: "others.m4a", frames: 2_076_000 * Meeting.framesPerMs,
                gaps: [Meeting.Span(startMs: 1_840_000, endMs: 1_902_000)]),
        ],
        audio: Meeting.Audio(
            inputDevice: "MacBook Pro Microphone", outputDevice: "MacBook Pro Speakers",
            outputTransport: "bltn", outputDataSource: "ispk"),
        echo: .affected,
        bothSilentMs: 0,
        dictations: [
            Meeting.Dictation(
                startMs: 923_000, endMs: 931_000,
                historyId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!),
        ],
        speakers: [
            Meeting.Speaker(id: "you", name: "You", isYou: true, talkMs: 394_000),
            Meeting.Speaker(id: "them", name: "Them", isYou: false, talkMs: 1_413_000),
        ],
        transcription: Meeting.Transcription(
            state: .done, error: nil, asr: "parakeet-unified-en-0.6b-Q8_0", diarizer: nil,
            tookMs: 41_000, done: ["mic": 18, "others": 18]),
        paragraphs: [
            Meeting.Paragraph(
                speaker: "you", startMs: 14_000, endMs: 21_000,
                text: "Morning. Shall we start with the deploy?"),
            Meeting.Paragraph(
                speaker: "them", startMs: 21_000, endMs: 30_000,
                text: "Sure, give me a second to pull it up."),
        ])
}
