import Foundation

/// One meeting: `meeting.json` in its folder. This is the truth;
/// `transcript.md` is rendered from it and never read. Times in
/// milliseconds are meeting time, sample index over the track rate, so a
/// word's timestamp is its position in every track (docs/meetings.md 5.4).
struct Meeting: Codable, Equatable, Sendable, Identifiable {
    /// The schema this build writes. A file with a higher one is left alone.
    static let currentSchema = 1
    /// Frames per millisecond of a 16 kHz track: `frames == durationMs × 16`.
    static let framesPerMs = Int(AudioCapture.targetFormat.sampleRate) / 1000

    enum Kind: String, Codable, Sendable { case call, room }
    enum TitleSource: String, Codable, Sendable { case app, user, generated, roster }
    enum Echo: String, Codable, Sendable { case notMeasured, clean, affected }
    /// Nil means recorded by this app; `imported` is a file brought in from
    /// elsewhere (docs/meetings.md D21).
    enum Source: String, Codable, Sendable { case recorded, imported }

    struct App: Codable, Equatable, Sendable {
        var bundleId: String
        var name: String
    }

    struct Span: Codable, Equatable, Sendable {
        var startMs: Int
        var endMs: Int
    }

    struct Track: Codable, Equatable, Sendable {
        enum Role: String, Codable, Sendable { case mic, others, room }
        var role: Role
        /// The file name inside the meeting folder: `.caf` while recording
        /// and transcribing, `.m4a` once transcoded.
        var file: String
        var frames: Int
        /// Stretches of zeros: a drop and rejoin, or a device rebuild.
        var gaps: [Span] = []
        /// The loudest sample, so a track that never left the floor is known.
        var peak: Float?
    }

    /// The kind of devices in use, never their names: a device name is
    /// user-authored and routinely a person's ("Michael's AirPods Pro").
    struct Audio: Codable, Equatable, Sendable {
        var inputTransport: String?
        var outputTransport: String?
        var outputDataSource: String?
    }

    struct Dictation: Codable, Equatable, Sendable {
        var startMs: Int
        var endMs: Int
        var historyId: UUID
    }

    struct Speaker: Codable, Equatable, Sendable, Identifiable {
        /// The speaker ids phase 1 uses: the mic track, the far end, a room.
        static let you = "you"
        static let them = "them"
        static let room = "room"

        var id: String
        var name: String
        var isYou: Bool
        var talkMs: Int
    }

    struct Transcription: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case pending, running, done, failed }
        var state: State
        var error: String?
        var asr: String?
        var diarizer: String?
        var tookMs: Int?
        /// Chunks finished per track role, so a run that stops resumes at
        /// the first chunk not counted here.
        var done: [String: Int] = [:]
    }

    struct Paragraph: Codable, Equatable, Sendable {
        var speaker: String
        var startMs: Int
        var endMs: Int
        var text: String
    }

    var schema: Int = Meeting.currentSchema
    var id: UUID
    var kind: Kind
    var started: Date
    var timeZone: String
    var ended: Date?
    var durationMs: Int
    var recordedMs: Int
    var firstHostTime: UInt64?
    /// How much of the recording came before the user said record (D20).
    var preRollMs: Int?
    var app: App?
    var title: String
    var titleSource: TitleSource
    var published: Bool
    var tracks: [Track]
    var audio: Audio?
    var echo: Echo
    var bothSilentMs: Int
    var dictations: [Dictation]
    var speakers: [Speaker]
    var transcription: Transcription
    var paragraphs: [Paragraph]
    /// Nil for a meeting this app recorded.
    var source: Source? = nil
    /// The imported file's basename only, never its path (docs/meetings.md 7.14).
    var importedFrom: String? = nil

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Unknown keys are ignored. A file written by a later schema is nil,
    /// with a log line, so this build never rewrites what it cannot read.
    static func decode(_ data: Data) -> Meeting? {
        do {
            let meeting = try decoder.decode(Meeting.self, from: data)
            guard meeting.schema <= currentSchema else {
                Log.meetings.error("meeting.json schema \(meeting.schema) is newer than \(currentSchema); left alone")
                return nil
            }
            return meeting
        } catch {
            Log.meetings.error("Could not read meeting.json: \(error.localizedDescription)")
            return nil
        }
    }

    func encoded() throws -> Data { try Meeting.encoder.encode(self) }

    // MARK: Derived

    var speakerCount: Int { speakers.count }

    var duration: Duration { .milliseconds(durationMs) }

    var isDone: Bool { transcription.state == .done }

    /// The others track never left the floor: the far end was silent, or
    /// the system-audio grant was missing (docs/meetings.md D13).
    var onlyYourSide: Bool {
        guard kind == .call, let peak = tracks.first(where: { $0.role == .others })?.peak else { return false }
        return peak < Fixed.meetingSilenceFloor
    }

    /// The tracks that have a playable `.m4a`, in file order.
    var audioFiles: [String] { tracks.map(\.file).filter { $0.hasSuffix(".m4a") } }

    /// The transcript as plain text, one paragraph per speaker turn.
    var transcriptText: String {
        paragraphs.map { "\(speakerName($0.speaker)): \($0.text)" }.joined(separator: "\n\n")
    }

    func speakerName(_ id: String) -> String {
        speakers.first { $0.id == id }?.name ?? id
    }
}

/// The words the speech model produced for one track, kept in a scratch
/// file beside `meeting.json` while a transcription runs.
struct TrackWords: Codable, Equatable, Sendable {
    let role: String
    var words: [Transcriber.Word]
}

/// One diarized stretch of one track (phase 2).
struct SpeakerSegment: Codable, Equatable, Sendable {
    let speaker: String
    let startMs: Int
    let endMs: Int
}
