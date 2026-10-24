import AppKit
import Foundation
import Observation

/// Which appearance the app's windows and the recording cloud take: the
/// system's, or light or dark regardless of it.
enum Appearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: "system"
        case .light: "light"
        case .dark: "dark"
        }
    }

    /// `nil` clears the override so the app follows the system again.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Every user-changeable value, backed by UserDefaults. Fixed values that are
/// not settings live in `Fixed`.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    /// Hooks `typemeit-mcp` writes from its own process: UserDefaults tells
    /// key-value observers of changes made by other processes.
    @ObservationIgnored private var hooksObservation: NSKeyValueObservation?
    @ObservationIgnored private var systemPromptObservation: NSKeyValueObservation?

    var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }
    // Mute and pause are alternatives: switching one on switches the other off.
    var muteWhileRecording: Bool {
        didSet {
            defaults.set(muteWhileRecording, forKey: "muteWhileRecording")
            if muteWhileRecording, pauseWhileRecording { pauseWhileRecording = false }
        }
    }
    var pauseWhileRecording: Bool {
        didSet {
            defaults.set(pauseWhileRecording, forKey: "pauseWhileRecording")
            if pauseWhileRecording, muteWhileRecording { muteWhileRecording = false }
        }
    }
    var audioFeedback: Bool { didSet { defaults.set(audioFeedback, forKey: "audioFeedback") } }
    var postProcessingEnabled: Bool { didSet { defaults.set(postProcessingEnabled, forKey: "postProcessingEnabled") } }
    var customWords: [String] { didSet { defaults.set(customWords, forKey: "customWords") } }
    /// The custom words plus the built-in ones the user has not listed.
    var matchedWords: [String] {
        CustomWordMatcher.builtInWords.filter { word in !customWords.contains { $0.caseInsensitiveCompare(word) == .orderedSame } } + customWords
    }
    /// The opinionated rewrites clean-up applies on top of its fixes.
    var writingStyles: Set<WritingStyle> { didSet { defaults.set(writingStyles.map(\.rawValue).sorted(), forKey: "writingStyles") } }
    var learnFromCorrections: Bool { didSet { defaults.set(learnFromCorrections, forKey: "learnFromCorrections") } }
    var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    /// Keeps each dictation's audio next to its history entry.
    var keepRecordings: Bool { didSet { defaults.set(keepRecordings, forKey: "keepRecordings") } }
    /// Checks for, downloads and installs updates on its own. Off, the app
    /// looks for an update only when Settings comes to the front, and installs
    /// one only from the version row's button.
    var autoUpdate: Bool { didSet { defaults.set(autoUpdate, forKey: "autoUpdate") } }
    /// With `autoUpdate` on: a ready update is announced with the pill and
    /// waits for a click. Off, the app installs it and restarts itself once no
    /// dictation is in flight.
    var askBeforeUpdating: Bool { didSet { defaults.set(askBeforeUpdating, forKey: "askBeforeUpdating") } }
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    /// Off, the cloud is dynamic: white or black against what is behind it.
    var cloudColorEnabled: Bool { didSet { defaults.set(cloudColorEnabled, forKey: "cloudColorEnabled") } }
    var cloudColor: CloudColor { didSet { defaults.set(cloudColor.rawValue, forKey: "cloudColor") } }
    /// What the last sample found behind the cloud. The next dynamic cloud
    /// starts from it, until its own sample arrives.
    var lastBackdrop: ScreenSampler.Backdrop? { didSet { defaults.set(lastBackdrop?.rawValue, forKey: "lastBackdrop") } }
    var cloudPosition: CloudPosition { didSet { defaults.set(cloudPosition.rawValue, forKey: "cloudPosition") } }
    /// A cloud with no colour of its own samples the screen under it and goes
    /// white or black against it. Needs Screen Recording; without the grant
    /// the appearance decides.
    var cloudMatchesBackdrop: Bool { !cloudColorEnabled }
    /// The cloud's colour as the settings offer it, one choice over the
    /// switch and colour above. The overlay reads those.
    var cloudChoice: CloudChoice {
        get { cloudColorEnabled ? .colour(cloudColor) : .dynamic }
        set {
            switch newValue {
            case .dynamic:
                cloudColorEnabled = false
            case .colour(let c):
                cloudColorEnabled = true
                cloudColor = c
            }
        }
    }
    /// The clean-up model is told the names and terms visible in the window
    /// being dictated into. Needs Screen Recording.
    var screenContextEnabled: Bool { didSet { defaults.set(screenContextEnabled, forKey: "screenContextEnabled") } }
    var onboardingComplete: Bool { didSet { defaults.set(onboardingComplete, forKey: "onboardingComplete") } }
    /// `ModelStore.version` of the speech model last installed here. Nil
    /// before the first install, and on a Mac that still has only the
    /// model this one replaced.
    var speechModelVersion: String? { didSet { defaults.set(speechModelVersion, forKey: "speechModelVersion") } }
    /// Copies the newest transcript to the clipboard. Nil means no shortcut.
    var copyLastShortcut: KeyCombo? {
        didSet { defaults.set(copyLastShortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: "copyLastShortcut") }
    }
    /// Words removed by the learned-words toast's Undo. Never learned again.
    var undoneWords: [String] { didSet { defaults.set(undoneWords, forKey: "undoneWords") } }
    /// Ask to record when another app opens the microphone. Off, the menu
    /// item is the only way to record a call.
    var meetingAsk: Bool { didSet { defaults.set(meetingAsk, forKey: "meetingAsk") } }
    /// While a call is being asked about, hold its last two minutes in
    /// memory so a meeting does not start at the click (D20).
    var meetingPreRoll: Bool { didSet { defaults.set(meetingPreRoll, forKey: "meetingPreRoll") } }
    /// Lets the bundled `typemeit-mcp` answer: other tools can list, search
    /// and read published meetings and dictations (D22). The binary reads
    /// this key itself; it keeps its first name from when it covered meetings
    /// only, so the switch stays as people set it.
    var mcpEnabled: Bool { didSet { defaults.set(mcpEnabled, forKey: "meetingsMCP") } }
    var mcpOffTools: [String] { didSet { defaults.set(mcpOffTools, forKey: MCPDefaults.offToolsKey) } }
    /// Keeps a meeting's tracks, compressed, beside its transcript.
    var meetingKeepAudio: Bool { didSet { defaults.set(meetingKeepAudio, forKey: "meetingKeepAudio") } }
    /// Keeps the voices of transcribed speakers on this Mac, to suggest names
    /// for numbered speakers from people named before (docs/meetings.md 8.7).
    /// Off deletes them.
    var meetingLearnVoices: Bool { didSet { defaults.set(meetingLearnVoices, forKey: "meetingLearnVoices") } }
    /// After a meeting, the pill offers okay and later before transcribing.
    var meetingAskBeforeTranscribing: Bool { didSet { defaults.set(meetingAskBeforeTranscribing, forKey: "meetingAskBeforeTranscribing") } }
    /// How many meetings to keep; 0 keeps everything.
    var meetingLimit: Int { didSet { defaults.set(meetingLimit, forKey: "meetingLimit") } }
    /// Offers questions heard in a meeting to Claude Code (`claude -p`).
    /// Only where `ClaudeRun.isAvailable`: installed, and not sandboxed.
    var askClaude: Bool { didSet { defaults.set(askClaude, forKey: "askClaude") } }
    /// Where Claude Code runs, which decides the project MCP servers and
    /// settings it loads.
    /// Offers questions the app spots on its own; off, only questions asked
    /// by name or from the menu go to Claude Code.
    /// The user's own system prompt, added after the app's on every ask.
    /// Prompts run on a finished meeting, in order, from its pill or page.
    /// Also written by `typemeit-mcp` from its own process; `hooksObservation` brings those writes in.
    var meetingHooks: [MeetingHook] { didSet { defaults.set(try? JSONEncoder().encode(meetingHooks), forKey: MeetingHook.defaultsKey) } }
    var askClaudeSystemPrompt: String { didSet { defaults.set(askClaudeSystemPrompt, forKey: MCPDefaults.systemPromptKey) } }
    /// Claude Code's `--permission-mode`, one of `ClaudeRun.permissionModes`.
    var askClaudePermissionMode: String { didSet { defaults.set(askClaudePermissionMode, forKey: "askClaudePermissionMode") } }
    var askClaudeFolder: String { didSet { defaults.set(askClaudeFolder, forKey: "askClaudeFolder") } }
    /// A Claude Code model alias for `--model`; `default` leaves the choice
    /// to Claude Code, whose default depends on the plan.
    var askClaudeModel: String { didSet { defaults.set(askClaudeModel, forKey: "askClaudeModel") } }
    /// Tools Claude Code may use without its auto-mode classifier reviewing
    /// them, in its `--allowedTools` syntax. Empty leaves every action to the
    /// classifier.
    var askClaudeTools: [String] { didSet { defaults.set(askClaudeTools, forKey: "askClaudeTools") } }
    /// Starts and stops a room recording. Nil means no shortcut.
    var recordRoomShortcut: KeyCombo? {
        didSet { defaults.set(recordRoomShortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: "recordRoomShortcut") }
    }
    /// Writes what each dictation and paste did to `DebugLog.url`, naming
    /// the app, the clipboard's contents and the start of the transcript.
    /// For bug reports.
    var debugLogs: Bool {
        didSet {
            defaults.set(debugLogs, forKey: "debugLogs")
            DebugLog.enabled = debugLogs
            if debugLogs { DebugLog.writeHeader() }
        }
    }

    private init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
        microphoneUID = d.string(forKey: "microphoneUID")
        muteWhileRecording = bool("muteWhileRecording", true)
        pauseWhileRecording = bool("pauseWhileRecording", false)
        audioFeedback = bool("audioFeedback", true)
        postProcessingEnabled = bool("postProcessingEnabled", true)
        customWords = d.stringArray(forKey: "customWords") ?? []
        writingStyles = Set((d.stringArray(forKey: "writingStyles") ?? []).compactMap(WritingStyle.init))
        learnFromCorrections = bool("learnFromCorrections", true)
        historyLimit = d.object(forKey: "historyLimit") == nil ? 0 : d.integer(forKey: "historyLimit")
        keepRecordings = bool("keepRecordings", Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true)
        autoUpdate = bool("autoUpdate", true)
        askBeforeUpdating = bool("askBeforeUpdating", true)
        launchAtLogin = bool("launchAtLogin", true)
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        cloudColorEnabled = bool("cloudColorEnabled", false)
        cloudColor = CloudColor(rawValue: d.string(forKey: "cloudColor") ?? "") ?? .coral
        lastBackdrop = ScreenSampler.Backdrop(rawValue: d.string(forKey: "lastBackdrop") ?? "")
        cloudPosition = CloudPosition(rawValue: d.string(forKey: "cloudPosition") ?? "") ?? .centre
        screenContextEnabled = bool("screenContextEnabled", false)
        onboardingComplete = bool("onboardingComplete", false)
        speechModelVersion = d.string(forKey: "speechModelVersion")
        copyLastShortcut = d.data(forKey: "copyLastShortcut").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
        undoneWords = d.stringArray(forKey: "undoneWords") ?? []
        meetingAsk = bool("meetingAsk", true)
        meetingPreRoll = bool("meetingPreRoll", true)
        mcpEnabled = bool("meetingsMCP", false)
        mcpOffTools = d.stringArray(forKey: MCPDefaults.offToolsKey) ?? []
        meetingKeepAudio = bool("meetingKeepAudio", true)
        meetingLearnVoices = bool("meetingLearnVoices", false)
        meetingAskBeforeTranscribing = bool("meetingAskBeforeTranscribing", false)
        meetingLimit = d.object(forKey: "meetingLimit") == nil ? 0 : d.integer(forKey: "meetingLimit")
        askClaude = bool("askClaude", Updates.isDevBuild)
        askClaudeSystemPrompt = d.string(forKey: MCPDefaults.systemPromptKey) ?? ""
        meetingHooks = Settings.storedHooks(d)
        askClaudePermissionMode = d.string(forKey: "askClaudePermissionMode") ?? "auto"
        askClaudeFolder = d.string(forKey: "askClaudeFolder") ?? FileManager.default.homeDirectoryForCurrentUser.path
        askClaudeTools = d.stringArray(forKey: "askClaudeTools") ?? []
        askClaudeModel = d.string(forKey: "askClaudeModel") ?? ClaudeRun.defaultModel
        recordRoomShortcut = d.data(forKey: "recordRoomShortcut").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
        debugLogs = bool("debugLogs", false)
        DebugLog.enabled = debugLogs
        if debugLogs { DebugLog.writeHeader() }
        systemPromptObservation = d.observe(\.askClaudeSystemPrompt) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let stored = self.defaults.string(forKey: MCPDefaults.systemPromptKey) ?? ""
                if stored != self.askClaudeSystemPrompt { self.askClaudeSystemPrompt = stored }
            }
        }
        hooksObservation = d.observe(\.meetingHooks) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                // Our own write comes back here too; only an outside one differs.
                let stored = Settings.storedHooks(self.defaults)
                if stored != self.meetingHooks { self.meetingHooks = stored }
            }
        }
    }

    private static func storedHooks(_ defaults: UserDefaults) -> [MeetingHook] {
        defaults.data(forKey: MeetingHook.defaultsKey).flatMap { try? JSONDecoder().decode([MeetingHook].self, from: $0) } ?? []
    }

    func addCustomWord(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !customWords.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        customWords.insert(w, at: 0)
    }

    func removeCustomWord(_ word: String) {
        customWords.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
    }
}

extension UserDefaults {
    /// Named for `MeetingHook.defaultsKey`, so it can be observed.
    @objc dynamic var meetingHooks: Data? { data(forKey: MeetingHook.defaultsKey) }
    /// Named for `MCPDefaults.systemPromptKey`, which the MCP server writes.
    @objc dynamic var askClaudeSystemPrompt: String? { string(forKey: MCPDefaults.systemPromptKey) }
}

/// Values that are built in and have no UI.
enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

enum Fixed {
    static let websiteURL = URL(string: "https://typeme.it")!
    static let contactEmail = "hello@typeme.it"
    static let contactURL = URL(string: "mailto:\(contactEmail)")!
    /// The GitHub release page for a version, linked from the about row.
    static func releaseURL(_ version: String) -> String { "https://github.com/typemeit/typemeit/releases/tag/v\(version)" }
    static let holdThresholdMs = 300
    /// The microphone stays open this long after a dictation is stopped, so
    /// a last word said as Fn goes up is not cut off.
    static let recordingTail: Duration = .milliseconds(300)
    static let pasteDelayBeforeMs = 60
    /// Restore this long after the target read the clipboard. Chromium's
    /// browser process reads, then the renderer reads the pasteboard's copy.
    static let pasteQuietMs = 200
    /// Restore, and Return, this long after Cmd+V when something read the
    /// clipboard before the chord and the target's read cannot be seen.
    static let pasteReadEarlyMs = 1500
    /// Restore this long after Cmd+V when nothing has read the clipboard.
    static let pasteUnreadCapMs = 8000
    /// Nothing has read the clipboard this long after Cmd+V: the paste
    /// landed nowhere, and the copy prompt shows. Slack under load read at
    /// 273 ms.
    static let pasteLandedWaitMs = 1000
    /// Restore this long after a Cmd+V that could not be posted.
    static let pasteNotPostedMs = 500
    static let pasteTickMs = 20
    /// A dictation that waited longer than this for the speech model's turn is logged.
    static let slowTranscriberWait: Duration = .milliseconds(500)
    static let copyPromptTimeout: Duration = .seconds(8)
    static let minimumRecordingSeconds = 0.3
    /// A screen read serves every dictation into the same window this long.
    static let screenReadReuse: Duration = .seconds(60)
    static let silencePeak: Float = 0.01
    static let learningAppDenylist: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.lastpass.LastPass", "com.apple.keychainaccess", "com.apple.Terminal",
        "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    ]

    // MARK: Meetings (docs/meetings.md 7.8; each value's source is beside it)

    /// A call is confirmed from booleans, not audio: input and output both
    /// running on one app this long. The pre-roll keeps what came before the
    /// prompt, so this only delays it; 12 s left the user waiting on every call.
    static let meetingConfirmSeconds = 4
    /// atrium's confirm window, repurposed: input with no output this long
    /// is a mic test, not a call.
    static let meetingArmTimeoutSeconds = 90
    /// atrium: how long a cross is remembered after the app drops the mic.
    static let meetingRejoinSeconds = 120
    /// A dropped call rejoins in seconds; a different call in the same app
    /// inside 30 s is unlikely, and the pill covers it.
    static let meetingResumeSeconds = 30
    /// atrium, applied to recorded audio: a shorter call is not kept.
    static let meetingMinimumSeconds = 90
    /// A call recorded again within this long of its last recording ending
    /// joins that meeting instead of starting a new one.
    static let meetingRejoinMergeMinutes = 15
    /// An app that never releases the mic.
    static let meetingSessionCapSeconds = 4 * 60 * 60
    /// meeting-transcriber `SilentRecordingMonitor`: every track at the floor
    /// this long means the tap is silent, or everyone is muted.
    static let meetingSilentSeconds = 90
    /// meeting-transcriber `SilentRecordingMonitor`: −60 dBFS.
    static let meetingSilenceFloor: Float = 0.001
    /// An idle call, or a forgotten room recording, ends after this long at
    /// the floor.
    static let meetingBothSilentEndSeconds = 600
    /// One rebuild usually suffices; three a second apart cover a slow USB
    /// re-enumeration.
    static let meetingRebuildAttempts = 3
    static let meetingRebuildIntervalSeconds = 1
    /// The writers flush in milliseconds; two seconds bounds a stuck disk.
    static let meetingQuitWaitSeconds = 2
    /// How long the pill offers okay and later before a meeting is
    /// transcribed, when asking is on. The owner's choice.
    static let meetingTranscribeAskSeconds = 5
    /// Longer than a prompt is ever left unanswered; 15.4 MB for a call (D20).
    static let meetingPreRollSeconds = 120
    /// The process-list listener fires several times per launch.
    static let meetingWatchDebounce: Duration = .milliseconds(250)
    /// The backstop the listeners need (docs/meetings.md 3.2).
    static let meetingWatchPollSeconds = 1
    /// How long the drain can fall behind before audio is dropped. 4 s was
    /// not enough on 16 October: on a flat battery the drain lost 72 s of a
    /// 13-minute call; a drop now logs "Meeting capture fell behind".
    static let meetingRingSeconds = 20
    /// Chosen, not measured: 4,800 frames a drain at 48 kHz, and the tick
    /// the tab's meters read at 10 Hz.
    static let meetingDrainMs = 100
    /// S2 (docs/meetings.md 6): the longest stretch Parakeet is handed.
    static let meetingChunkSeconds = 120
    /// Parakeet stretches a sentence's last word to its next token, across
    /// any silence after it: up to 23 s on the 25 September call's far end,
    /// where the median word is 80 ms and the mic's longest was 560 ms. A
    /// stretched word would carry its paragraph over the other speaker.
    static let meetingLongestWordMs = 1000
    static let meetingChunkOverlapSeconds = 2
    /// The seam is placed at the quietest point within this of the nominal cut.
    static let meetingChunkSearchSeconds = 5
    /// A chunk with speech in it that comes back with no words is retried
    /// once, trimmed and louder: Parakeet returns nothing on quiet speech.
    /// Every value is r3dbars/transcripted's dictation recovery (MIT) on its
    /// own runtime of the same model family (docs/meetings.md 7.10).
    static let meetingQuietPeak: Float = 0.010
    static let meetingQuietRMS: Float = 0.0015
    /// A sample is active above this share of the chunk's peak, clamped.
    static let meetingQuietActivityShare: Float = 0.08
    static let meetingQuietActivityFloor: Float = 0.003
    static let meetingQuietActivityCeiling: Float = 0.020
    /// Speech is at least this share of samples active, and this much time of them.
    static let meetingQuietActiveShare = 0.005
    static let meetingQuietActiveSeconds = 0.2
    /// The retry keeps this much either side of the first and last active sample.
    static let meetingQuietPadSeconds = 0.25
    /// And scales so the peak lands here, with the gain held to this range.
    static let meetingQuietTargetPeak: Float = 0.45
    static let meetingQuietGainRange: ClosedRange<Float> = 1...12
    /// A pause this long ends a speaker's turn, so whoever speaks after it
    /// can start a paragraph of their own. A pause alone never starts one:
    /// one speaker's paragraphs with nobody else's between them are joined.
    static let meetingParagraphGapSeconds = 2
    /// NAME_MAX is 255 bytes.
    static let meetingFolderNameMax = 200
    /// Two raw tracks are 230 MB an hour.
    static let meetingMinimumFreeBytes: Int64 = 500 << 20
    /// Opus at 16 kbps, which averages about 7 kbps on speech with pauses.
    /// Measured 24 September 2026 on ten minutes of a call's far end: it
    /// changed 1.7% of the transcript's words against the uncompressed
    /// track, the same as AAC at 32 kbps (1.5%) at a quarter of the size;
    /// AAC at 16 kbps changed 4.9%, Opus at 12 kbps 3.6%.
    static let meetingAudioBitrate = 16_000
    /// Daemons that hold the mic for an app with no process of its own
    /// (docs/meetings.md 3.2: FaceTime's input belongs to avconferenced).
    static let meetingDaemonNames: [String: String] = [
        "com.apple.avconferenced": "FaceTime",
    ]
    /// Apple daemons that hold the mic for the system. Added to only from a
    /// debug log that shows a false prompt.
    static let meetingIgnoredBundleIDs: Set<String> = [
        "com.apple.CoreSpeech", "com.apple.assistantd", "com.apple.universalaccessd",
        "com.apple.accessibility.heard", "com.apple.systemsoundserverd",
    ]
    /// FluidAudio's segmentation step ratio: its default 0.2; its docs say
    /// 0.1 measures best on far-field meetings with rapid exchanges. S3
    /// (docs/meetings.md 6) picks between them; until it runs, the default.
    static let meetingDiarizerStepRatio = 0.2
    /// S3, from humla (MIT) and measured here: see `Diarizer.configuration`.
    static let meetingDiarizerMinOnSeconds = 1.0
    static let meetingDiarizerMinOffSeconds = 0.5
    /// A 10 ms frame is a speaker's when Nemotron gives them more than this
    /// and more than anyone else: FluidAudio's own threshold for its segments.
    static let meetingTurnThreshold: Float = 0.5
    /// A Nemotron turn shorter than this is dropped: FluidAudio's own minimum.
    static let meetingTurnMinimumMs = 200
    /// How much of a speaker's longest turns the embedding model hears.
    static let meetingEmbeddingClipSeconds = 30
    /// Two voices heard through one tile stay two people when their
    /// `SpeakerMerge.meanDistance` is this or more. Measured over 20 s clips
    /// on kept calls: the same voice 0.15 to 0.25; one person Nemotron split
    /// in two 0.57 (9 October); two people sharing a tile 0.66 (12 October);
    /// two people on separate tiles from 0.65.
    static let meetingDistinctVoiceDistance: Float = 0.6
    /// The clips `meetingDistinctVoiceDistance` is measured over: up to this
    /// many of this length from each speaker's longest turns.
    static let meetingVoiceClipSeconds = 20
    static let meetingVoiceClips = 6
    /// A diarized speaker with less talk than this is folded into the
    /// nearest voice. The 24 September Slack call's one far-end person came
    /// out as two, one of them 4 s. On the two earlier calls, where
    /// AssemblyAI found 3 and 4 far-end speakers to our 5 and 5, the
    /// smallest were 8 s and 2 s; folding them gives 4 and 4.
    static let meetingMinimumSpeakerSeconds = 10
    /// A mic voice the far end has words over for this share of its time is
    /// the loudspeaker coming back. On the 29 September speakers call the remote
    /// voice's echo measured 0.63 and the two people at the laptop 0.01 and 0.05.
    static let meetingEchoVoiceShare = 0.3
    /// Every WKWebView app shares this audio process, Safari included, so it
    /// is named `web content` and never put on the never-ask list.
    static let meetingWebContentBundleID = "com.apple.WebKit.GPU"
    /// The delay between a voice reaching the far-end track and the UI
    /// indicator lighting. 0 until S4 measures it (median of ten claps).
    static let meetingUILagMs = 0
    /// How often the meeting's participant tiles are read while recording: a
    /// turn shorter than this is a backchannel, not a speaker (docs/meetings.md 7.8).
    static let meetingSpeakingPollMs = 250
    /// How often the whole meeting window is walked while recording, for the
    /// call's code or channel and for tiles that came or went.
    static let meetingRosterWalkSeconds = 5
    /// A speaker stays speaking through a gap in the indicator this long:
    /// Meet's highlight goes out between words, Slack's lingers about 1.5 s.
    static let meetingSpeakingHoldMs = 1000
    /// Token containment between a caption line and a paragraph, as in the
    /// echo work.
    static let meetingCaptionMatch = 0.5
    /// Enough speech to tell two people apart.
    static let meetingNameMinOverlapSeconds = 20
    /// A name has to clearly win over the runner-up.
    static let meetingNameMargin = 1.5
    /// Voice names (docs/meetings.md 8.7), from the 6 October calls: a clip
    /// shorter than this is too little voice to learn from.
    static let meetingVoiceShortestMs = 1500
    /// A clip another speaker on its track covers for more of it than this is left out.
    static let meetingVoiceCrosstalkShare = 0.1
    /// A far-end paragraph is taken from the mic as echo only with no mic
    /// paragraph this close on either side.
    static let meetingVoiceEchoPadMs = 500
    /// A name is suggested at this posterior. On 22 October, with tiled
    /// clips, 2 of 326 strangers reached it, as at 0.7; 0.6 let 4 through.
    static let meetingVoiceSuggestPosterior: Float = 0.8
    /// A speaker needs this many clips for a suggestion.
    static let meetingVoiceMinimumClips = 3
    /// The voice model's training: steps, rate and momentum of its gradient
    /// descent, which converge on the 6 October calls' 7,000 clips.
    static let meetingVoiceTrainingSteps = 300
    static let meetingVoiceTrainingRate: Float = 4
    static let meetingVoiceTrainingMomentum: Float = 0.9
}
