import Foundation

/// One meeting: `meeting.json` in its folder. This is the truth;
/// `transcript.md` is rendered from it and never read. Times in
/// milliseconds are meeting time, sample index over the track rate, so a
/// word's timestamp is its position in every track (docs/meetings.md 5.4).
struct Meeting: Codable, Equatable, Sendable, Identifiable {
    /// The one-line reminder `get_meeting` and `search_meetings` carry in the
    /// result itself (docs/meetings.md 7.15), since a client that only saw
    /// the tool description once may not see it again by the time the
    /// meeting text arrives. The app's Claude output leaves it out.
    static let dataReminder = MeetingDataReminder.line

    /// The schema this build writes. A file with a higher one is left alone.
    static let currentSchema = 1
    /// Frames per millisecond of a 16 kHz track: `frames == durationMs × 16`.
    static let framesPerMs = Int(AudioCapture.targetFormat.sampleRate) / 1000

    /// `45s` under a minute (whole seconds, so never `60s`), then `8m`,
    /// `45m`, `1h20m`, rounded to the nearest minute. Folder names, insights
    /// and the MCP server all show this one label.
    static func durationLabel(_ duration: Duration) -> String {
        let seconds = duration / .seconds(1)
        guard seconds >= 60 else { return "\(Int(seconds))s" }
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard hours > 0 else { return "\(minutes)m" }
        return "\(hours)h\(minutes)m"
    }

    enum Kind: String, Codable, Sendable { case call, room }
    enum TitleSource: String, Codable, Sendable { case app, user, generated, roster }
    enum Echo: String, Codable, Sendable { case notMeasured, clean, affected }

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
        /// The file name inside the meeting folder: `mic.caf` (16-bit PCM)
        /// while recording and transcribing, `mic.opus.caf` once
        /// transcoded; meetings from before Opus keep `mic.m4a`.
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

        /// What the far end is called until someone is named.
        static let themName = "Them"

        /// What a diarized speaker no one has named is called: "Speaker 2".
        static func numberedName(_ n: Int) -> String { "Speaker \(n)" }

        /// A name this build gives a speaker no one has named. A meeting
        /// opened from someone's `.tmi` file carries theirs as given names.
        static func isPlaceholder(_ name: String) -> Bool {
            let prefix = String(numberedName(0).dropLast())
            if name == themName { return true }
            guard name.hasPrefix(prefix), let n = Int(name.dropFirst(prefix.count)) else { return false }
            return numberedName(n) == name
        }

        var id: String
        var name: String
        var isYou: Bool
        var talkMs: Int
        /// How this speaker got its name (docs/meetings.md 8.6). Nil for a
        /// speaker still labelled by number.
        var nameSource: MeetingNames.Source? = nil
    }

    struct Transcription: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case pending, running, done, failed }
        var state: State
        var error: String?
        var asr: String?
        var diarizer: String?
        var tookMs: Int?
        /// What the last pass spent on the words, the speakers, and the title
        /// and summary.
        var asrMs: Int?
        var speakersMs: Int?
        var summaryMs: Int?
        /// Chunks finished per track role, so a run that stops resumes at
        /// the first chunk not counted here.
        var done: [String: Int] = [:]
    }

    /// A question heard in the meeting that the app offered to ask Claude
    /// Code (Settings.askClaude), what the user did with it, and the answer.
    struct Question: Codable, Equatable, Sendable {
        enum Outcome: String, Codable, Sendable {
            case asked
            /// The user said no.
            case dismissed
            /// The offer timed out, or the next question took its place.
            case ignored
            /// Asked, then stopped before Claude answered.
            case cancelled
        }

        var atMs: Int
        var text: String
        /// Claude Code's answer, or why there was none. Nil when it was not asked.
        var answer: String?
        /// Nil on a question kept when only asked ones were.
        var outcome: Outcome?
        /// The run in `ClaudeLive`, and Claude Code's session for `claude --resume`.
        var runID: UUID?
        var sessionID: String?

        var result: Outcome { outcome ?? .asked }

        /// Every question either list has, oldest first. Questions are only
        /// ever added, so two copies of a meeting never disagree on one.
        static func union(_ a: [Question], _ b: [Question]) -> [Question] {
            (a + b.filter { !a.contains($0) }).sorted { $0.atMs < $1.atMs }
        }
    }

    /// A hook the user ran on the meeting after it ended (Settings.meetingHooks),
    /// and what Claude Code said.
    struct HookRun: Codable, Equatable, Sendable {
        var id: UUID
        /// The hook's name and prompt as they were when it ran.
        var name: String
        var prompt: String
        var ranAt: Date
        /// Claude Code's reply, or why there was none.
        var output: String
        var failed: Bool
        /// What `claude --resume` takes to pick the run up again.
        var sessionID: String? = nil

        /// Every run either list has, oldest first. Runs are only ever added.
        static func union(_ a: [HookRun], _ b: [HookRun]) -> [HookRun] {
            (a + b.filter { run in !a.contains { $0.id == run.id } }).sorted { $0.ranAt < $1.ranAt }
        }
    }

    struct Paragraph: Codable, Equatable, Sendable {
        var speaker: String
        var startMs: Int
        var endMs: Int
        var text: String
        /// The speaker it had before the user merged that speaker into
        /// another, so the merge can be split again.
        var mergedFrom: String? = nil
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
    /// What the meeting itself showed about who is who (docs/meetings.md
    /// 8.6). Nil until phase 2's naming runs.
    var names: MeetingNames? = nil
    /// A few sentences from the on-device model, for the meeting's page.
    /// Not rendered into `transcript.md` and never returned by the MCP.
    var summary: String? = nil
    /// The meeting this recording is a rejoin of: it is joined onto that
    /// one before transcription and then deleted (`MeetingMerge`).
    var continues: UUID? = nil
    /// Who sent it, for a meeting opened from a `.tmi` file (`MeetingShare`);
    /// empty when the file did not say. Nil for one recorded on this Mac.
    var sharedBy: String? = nil
    /// Speakers the user merged into others, as they were, so a merge can
    /// be split again. Nil when nothing is merged.
    var mergedSpeakers: [Speaker]? = nil
    /// The questions offered to Claude Code during the meeting. Nil when none.
    var questions: [Question]? = nil
    /// The hooks run on the meeting since it ended. Nil when none.
    var hookRuns: [HookRun]? = nil

    /// Unknown keys are ignored. A file written by a later schema is nil,
    /// with a log line, so this build never rewrites what it cannot read.
    static func decode(_ data: Data) -> Meeting? {
        do {
            let meeting = try StoredJSON.decoder.decode(Meeting.self, from: data)
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

    func encoded() throws -> Data { try StoredJSON.fileEncoder.encode(self) }

    // MARK: Derived

    var speakerCount: Int { speakers.count }

    var duration: Duration { .milliseconds(durationMs) }

    var isDone: Bool { transcription.state == .done }

    /// Recorded here rather than opened from someone's `.tmi` file: only
    /// these count as the user's own time in meetings.
    var recordedHere: Bool { sharedBy == nil }

    /// The others track never left the floor: the far end was silent, or
    /// the system-audio grant was missing (docs/meetings.md D13).
    var onlyYourSide: Bool {
        guard kind == .call, let peak = tracks.first(where: { $0.role == .others })?.peak else { return false }
        return peak < Fixed.meetingSilenceFloor
    }

    /// What a kept track is transcoded to, beside the raw `<role>.caf`.
    static let keptAudioSuffix = ".opus.caf"

    /// The kept, compressed tracks, in file order: Opus, or AAC from
    /// meetings recorded before it.
    var audioFiles: [String] { tracks.map(\.file).filter { $0.hasSuffix(Meeting.keptAudioSuffix) || $0.hasSuffix(".m4a") } }

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
