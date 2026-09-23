import AVFoundation
import Foundation
import OSLog

// This file exists only in the `typemeit-mcp` target (docs/meetings.md
// 7.15). That target shares `TypeMeIt/Meetings/Meeting.swift`'s source
// rather than linking against the app module (an application target isn't a
// library another target can import), so it has no other way to provide the
// app-only symbols Meeting.swift references by name: `AudioCapture`,
// `Fixed`, `Log` and `Transcriber.Word`. Each shim below defines only the
// member Meeting.swift actually uses, copied from the app's own definition
// so the two are easy to compare; `TypeMeIt/AudioCapture.swift`,
// `TypeMeIt/Settings.swift` (docs/meetings.md 7.8), `TypeMeIt/Log.swift` and
// `TypeMeIt/Transcriber.swift` remain the source of truth. Do not add
// members here beyond what Meeting.swift references, and do not edit
// Meeting.swift to avoid this file.

/// Mirrors `TypeMeIt/AudioCapture.swift`'s `targetFormat`.
enum AudioCapture {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
}

/// Mirrors `TypeMeIt/Settings.swift`'s `Fixed.meetingSilenceFloor`
/// (docs/meetings.md 7.8: meeting-transcriber `SilentRecordingMonitor`,
/// −60 dBFS).
enum Fixed {
    static let meetingSilenceFloor: Float = 0.001
}

/// Mirrors `TypeMeIt/Log.swift`'s `Log.meetings` category.
enum Log {
    static let meetings = Logger(subsystem: "it.typeme.typemeit", category: "meetings")
}

/// Mirrors `TypeMeIt/Transcriber.swift`'s `Transcriber.Word`, which
/// `TrackWords` (Meeting.swift) holds an array of. The real type is nested in
/// an `actor`; nothing here needs actor isolation, so this is a plain enum
/// namespace instead.
enum Transcriber {
    struct Word: Sendable, Equatable, Codable {
        let text: String
        let confidence: Float
        let start: Duration
        let end: Duration
    }
}
