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
    static let shared = Settings(defaults: .standard)

    private let defaults: UserDefaults
    /// Hooks `typemeit-mcp` writes from its own process: UserDefaults tells
    /// key-value observers of changes made by other processes.
    @ObservationIgnored private var hooksObservation: NSKeyValueObservation?
    @ObservationIgnored private var systemPromptObservation: NSKeyValueObservation?

    var microphoneUID: String? { didSet { Stored.microphoneUID.save(microphoneUID, defaults) } }
    /// The picked mic's name, to find it again when its UID changes.
    var microphoneName: String? { didSet { Stored.microphoneName.save(microphoneName, defaults) } }
    // Mute and pause are alternatives: switching one on switches the other off.
    var muteWhileRecording: Bool {
        didSet {
            Stored.muteWhileRecording.save(muteWhileRecording, defaults)
            if muteWhileRecording, pauseWhileRecording { pauseWhileRecording = false }
        }
    }
    var pauseWhileRecording: Bool {
        didSet {
            Stored.pauseWhileRecording.save(pauseWhileRecording, defaults)
            if pauseWhileRecording, muteWhileRecording { muteWhileRecording = false }
        }
    }
    var audioFeedback: Bool { didSet { Stored.audioFeedback.save(audioFeedback, defaults) } }
    var postProcessingEnabled: Bool { didSet { Stored.postProcessingEnabled.save(postProcessingEnabled, defaults) } }
    var customWords: [String] { didSet { Stored.customWords.save(customWords, defaults) } }
    /// The custom words plus the built-in ones the user has not listed.
    var matchedWords: [String] {
        CustomWordMatcher.builtInWords.filter { word in !customWords.contains { $0.caseInsensitiveCompare(word) == .orderedSame } } + customWords
    }
    /// The opinionated rewrites clean-up applies on top of its fixes.
    var writingStyles: Set<WritingStyle> { didSet { Stored.writingStyles.save(writingStyles, defaults) } }
    var learnFromCorrections: Bool { didSet { Stored.learnFromCorrections.save(learnFromCorrections, defaults) } }
    var historyLimit: Int { didSet { Stored.historyLimit.save(historyLimit, defaults) } }
    /// Keeps each dictation's audio next to its history entry.
    var keepRecordings: Bool { didSet { Stored.keepRecordings.save(keepRecordings, defaults) } }
    /// Checks for, downloads and installs updates on its own. Off, the app
    /// looks for an update only when Settings comes to the front, and installs
    /// one only from the version row's button.
    var autoUpdate: Bool { didSet { Stored.autoUpdate.save(autoUpdate, defaults) } }
    /// With `autoUpdate` on: a ready update is announced with the pill and
    /// waits for a click. Off, the app installs it and restarts itself once no
    /// dictation is in flight.
    var askBeforeUpdating: Bool { didSet { Stored.askBeforeUpdating.save(askBeforeUpdating, defaults) } }
    var launchAtLogin: Bool { didSet { Stored.launchAtLogin.save(launchAtLogin, defaults) } }
    var appearance: Appearance { didSet { Stored.appearance.save(appearance, defaults) } }
    /// Off, the cloud is dynamic: white or black against what is behind it.
    var cloudColorEnabled: Bool { didSet { Stored.cloudColorEnabled.save(cloudColorEnabled, defaults) } }
    var cloudColor: CloudColor { didSet { Stored.cloudColor.save(cloudColor, defaults) } }
    /// What the last sample found behind the cloud. The next dynamic cloud
    /// starts from it, until its own sample arrives.
    var lastBackdrop: ScreenSampler.Backdrop? { didSet { Stored.lastBackdrop.save(lastBackdrop, defaults) } }
    var cloudPosition: CloudPosition { didSet { Stored.cloudPosition.save(cloudPosition, defaults) } }
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
    var screenContextEnabled: Bool { didSet { Stored.screenContextEnabled.save(screenContextEnabled, defaults) } }
    var onboardingComplete: Bool { didSet { Stored.onboardingComplete.save(onboardingComplete, defaults) } }
    /// `ModelStore.version` of the speech model last installed here. Nil
    /// before the first install, and on a Mac that still has only the
    /// model this one replaced.
    var speechModelVersion: String? { didSet { Stored.speechModelVersion.save(speechModelVersion, defaults) } }
    /// Copies the newest transcript to the clipboard. Nil means no shortcut.
    var copyLastShortcut: KeyCombo? {
        didSet { Stored.copyLastShortcut.save(copyLastShortcut, defaults) }
    }
    /// The key held to dictate where there is no Fn (`Sandbox.watchesFn`).
    var dictationShortcut: KeyCombo { didSet { Stored.dictationShortcut.save(dictationShortcut, defaults) } }
    /// Words removed by the learned-words toast's Undo. Never learned again.
    var undoneWords: [String] { didSet { Stored.undoneWords.save(undoneWords, defaults) } }
    /// Ask to record when another app opens the microphone. Off, the menu
    /// item is the only way to record a call.
    var meetingAsk: Bool { didSet { Stored.meetingAsk.save(meetingAsk, defaults) } }
    /// While a call is being asked about, hold its last two minutes in
    /// memory so a meeting does not start at the click (D20).
    var meetingPreRoll: Bool { didSet { Stored.meetingPreRoll.save(meetingPreRoll, defaults) } }
    /// Lets the bundled `typemeit-mcp` answer: other tools can list, search
    /// and read published meetings and dictations (D22). The binary reads
    /// this key itself; it keeps its first name from when it covered meetings
    /// only, so the switch stays as people set it.
    var mcpEnabled: Bool { didSet { Stored.mcpEnabled.save(mcpEnabled, defaults) } }
    var mcpOffTools: [String] { didSet { Stored.mcpOffTools.save(mcpOffTools, defaults) } }
    /// Keeps a meeting's tracks, compressed, beside its transcript.
    var meetingKeepAudio: Bool { didSet { Stored.meetingKeepAudio.save(meetingKeepAudio, defaults) } }
    /// Keeps the voices of transcribed speakers on this Mac, to suggest names
    /// for numbered speakers from people named before (docs/meetings.md 8.7).
    /// Off deletes them.
    var meetingLearnVoices: Bool { didSet { Stored.meetingLearnVoices.save(meetingLearnVoices, defaults) } }
    /// After a meeting, the pill offers okay and later before transcribing.
    var meetingAskBeforeTranscribing: Bool { didSet { Stored.meetingAskBeforeTranscribing.save(meetingAskBeforeTranscribing, defaults) } }
    /// How many meetings to keep; 0 keeps everything.
    var meetingLimit: Int { didSet { Stored.meetingLimit.save(meetingLimit, defaults) } }
    /// Offers questions heard in a meeting to Claude Code (`claude -p`).
    /// Only where `ClaudeRun.isAvailable`: installed, and not sandboxed.
    var askClaude: Bool { didSet { Stored.askClaude.save(askClaude, defaults) } }
    /// Where Claude Code runs, which decides the project MCP servers and
    /// settings it loads.
    /// Offers questions the app spots on its own; off, only questions asked
    /// by name or from the menu go to Claude Code.
    /// The user's own system prompt, added after the app's on every ask.
    /// Prompts run on a finished meeting, in order, from its pill or page.
    /// Also written by `typemeit-mcp` from its own process; `hooksObservation` brings those writes in.
    var meetingHooks: [MeetingHook] { didSet { Stored.meetingHooks.save(meetingHooks, defaults) } }
    var askClaudeSystemPrompt: String { didSet { Stored.askClaudeSystemPrompt.save(askClaudeSystemPrompt, defaults) } }
    /// Claude Code's `--permission-mode`, one of `ClaudeRun.permissionModes`.
    var askClaudePermissionMode: String { didSet { Stored.askClaudePermissionMode.save(askClaudePermissionMode, defaults) } }
    var askClaudeFolder: String { didSet { Stored.askClaudeFolder.save(askClaudeFolder, defaults) } }
    /// A Claude Code model alias for `--model`; `default` leaves the choice
    /// to Claude Code, whose default depends on the plan.
    var askClaudeModel: String { didSet { Stored.askClaudeModel.save(askClaudeModel, defaults) } }
    /// Tools Claude Code may use without its auto-mode classifier reviewing
    /// them, in its `--allowedTools` syntax. Empty leaves every action to the
    /// classifier.
    var askClaudeTools: [String] { didSet { Stored.askClaudeTools.save(askClaudeTools, defaults) } }
    /// The cloud and Claude's answers show on the type me it camera while a
    /// meeting records. Off, it shows the plain camera.
    var askClaudeOnCamera: Bool { didSet { Stored.askClaudeOnCamera.save(askClaudeOnCamera, defaults) } }
    /// The camera `CameraFeed` shows through the type me it camera: a
    /// capture device's unique id, or empty for the Mac's default camera.
    var meetingCamera: String { didSet { Stored.meetingCamera.save(meetingCamera, defaults) } }
    /// Starts and stops a room recording. Nil means no shortcut.
    var recordRoomShortcut: KeyCombo? {
        didSet { Stored.recordRoomShortcut.save(recordRoomShortcut, defaults) }
    }
    /// Writes what each dictation and paste did to `DebugLog.url`, naming
    /// the app, the clipboard's contents and the start of the transcript.
    /// For bug reports.
    var debugLogs: Bool {
        didSet {
            Stored.debugLogs.save(debugLogs, defaults)
            DebugLog.enabled = debugLogs
            if debugLogs { DebugLog.writeHeader() }
        }
    }

    /// Tests pass a throwaway suite; the app uses `shared`.
    init(defaults d: UserDefaults) {
        defaults = d
        microphoneUID = Stored.microphoneUID.load(d)
        microphoneName = Stored.microphoneName.load(d)
        muteWhileRecording = Stored.muteWhileRecording.load(d)
        pauseWhileRecording = Stored.pauseWhileRecording.load(d)
        audioFeedback = Stored.audioFeedback.load(d)
        postProcessingEnabled = Stored.postProcessingEnabled.load(d)
        customWords = Stored.customWords.load(d)
        writingStyles = Stored.writingStyles.load(d)
        learnFromCorrections = Stored.learnFromCorrections.load(d)
        historyLimit = Stored.historyLimit.load(d)
        keepRecordings = Stored.keepRecordings.load(d)
        autoUpdate = Stored.autoUpdate.load(d)
        askBeforeUpdating = Stored.askBeforeUpdating.load(d)
        launchAtLogin = Stored.launchAtLogin.load(d)
        appearance = Stored.appearance.load(d)
        cloudColorEnabled = Stored.cloudColorEnabled.load(d)
        cloudColor = Stored.cloudColor.load(d)
        lastBackdrop = Stored.lastBackdrop.load(d)
        cloudPosition = Stored.cloudPosition.load(d)
        screenContextEnabled = Stored.screenContextEnabled.load(d)
        onboardingComplete = Stored.onboardingComplete.load(d)
        speechModelVersion = Stored.speechModelVersion.load(d)
        copyLastShortcut = Stored.copyLastShortcut.load(d)
        dictationShortcut = Stored.dictationShortcut.load(d)
        undoneWords = Stored.undoneWords.load(d)
        meetingAsk = Stored.meetingAsk.load(d)
        meetingPreRoll = Stored.meetingPreRoll.load(d)
        mcpEnabled = Stored.mcpEnabled.load(d)
        mcpOffTools = Stored.mcpOffTools.load(d)
        meetingKeepAudio = Stored.meetingKeepAudio.load(d)
        meetingLearnVoices = Stored.meetingLearnVoices.load(d)
        meetingAskBeforeTranscribing = Stored.meetingAskBeforeTranscribing.load(d)
        meetingLimit = Stored.meetingLimit.load(d)
        askClaude = Stored.askClaude.load(d)
        askClaudeSystemPrompt = Stored.askClaudeSystemPrompt.load(d)
        meetingHooks = Stored.meetingHooks.load(d)
        askClaudePermissionMode = Stored.askClaudePermissionMode.load(d)
        askClaudeFolder = Stored.askClaudeFolder.load(d)
        askClaudeTools = Stored.askClaudeTools.load(d)
        askClaudeModel = Stored.askClaudeModel.load(d)
        askClaudeOnCamera = Stored.askClaudeOnCamera.load(d)
        meetingCamera = Stored.meetingCamera.load(d)
        recordRoomShortcut = Stored.recordRoomShortcut.load(d)
        debugLogs = Stored.debugLogs.load(d)
        DebugLog.enabled = debugLogs
        if debugLogs { DebugLog.writeHeader() }
        systemPromptObservation = d.observe(\.askClaudeSystemPrompt) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let stored = Stored.askClaudeSystemPrompt.load(self.defaults)
                if stored != self.askClaudeSystemPrompt { self.askClaudeSystemPrompt = stored }
            }
        }
        hooksObservation = d.observe(\.meetingHooks) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                // Our own write comes back here too; only an outside one differs.
                let stored = Stored.meetingHooks.load(self.defaults)
                if stored != self.meetingHooks { self.meetingHooks = stored }
            }
        }
    }

    func addCustomWord(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !customWords.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        customWords.insert(w, at: 0)
    }

    /// The picked mic's UID as it resolves now, nil for the system default.
    /// A USB mic's UID carries the port it is on, so behind a dock it can
    /// come back after sleep under a new one: the mic is then found by its
    /// name and the new UID stored. A mic picked before names were stored
    /// gets its name here. A mic not found keeps its UID, and the capture
    /// falls back to the default input as before.
    @discardableResult
    func connectedMicrophoneUID() -> String? {
        guard let uid = microphoneUID else { return nil }
        if let id = AudioCapture.deviceID(forUID: uid) {
            if microphoneName == nil { microphoneName = MeetingCapture.device(id)?.name }
            return uid
        }
        guard let name = microphoneName, let found = AudioCapture.uid(named: name, among: AudioCapture.connectedInputs()) else { return uid }
        DebugLog.write("Microphone: picked mic back under a new UID; stored it")
        microphoneUID = found
        return found
    }

    func removeCustomWord(_ word: String) {
        customWords.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
    }
}

extension Settings {
    /// Every setting's UserDefaults key and its value when nothing is stored.
    /// The keys are what people's settings are saved under: renaming one
    /// resets that setting for everyone.
    enum Stored {
        static let microphoneUID = StoredSetting<String?>.optionalString("microphoneUID")
        static let microphoneName = StoredSetting<String?>.optionalString("microphoneName")
        static let muteWhileRecording = StoredSetting.bool("muteWhileRecording", default: true)
        static let pauseWhileRecording = StoredSetting.bool("pauseWhileRecording", default: false)
        static let audioFeedback = StoredSetting.bool("audioFeedback", default: true)
        static let postProcessingEnabled = StoredSetting.bool("postProcessingEnabled", default: true)
        static let customWords = StoredSetting.strings("customWords")
        static let writingStyles = StoredSetting<Set<WritingStyle>>.rawSet("writingStyles")
        static let learnFromCorrections = StoredSetting.bool("learnFromCorrections", default: true)
        static let historyLimit = StoredSetting.int("historyLimit", default: 0)
        static let keepRecordings = StoredSetting.bool("keepRecordings", default: Updates.isDevBuild)
        static let autoUpdate = StoredSetting.bool("autoUpdate", default: true)
        static let askBeforeUpdating = StoredSetting.bool("askBeforeUpdating", default: true)
        // App Review refuses an app that adds itself to login items without
        // being asked (guideline 2.4.5), so the store build starts with it off.
        static let launchAtLogin = StoredSetting.bool("launchAtLogin", default: !Sandbox.isActive)
        static let appearance = StoredSetting.raw("appearance", default: Appearance.system)
        static let cloudColorEnabled = StoredSetting.bool("cloudColorEnabled", default: false)
        static let cloudColor = StoredSetting.raw("cloudColor", default: CloudColor.coral)
        static let lastBackdrop = StoredSetting<ScreenSampler.Backdrop?>.optionalRaw("lastBackdrop")
        static let cloudPosition = StoredSetting.raw("cloudPosition", default: CloudPosition.centre)
        static let screenContextEnabled = StoredSetting.bool("screenContextEnabled", default: false)
        static let onboardingComplete = StoredSetting.bool("onboardingComplete", default: false)
        static let speechModelVersion = StoredSetting<String?>.optionalString("speechModelVersion")
        static let copyLastShortcut = StoredSetting<KeyCombo?>.optionalJSON("copyLastShortcut")
        static let dictationShortcut = StoredSetting.json("dictationShortcut", default: KeyCombo.optionSpace)
        static let undoneWords = StoredSetting.strings("undoneWords")
        static let meetingAsk = StoredSetting.bool("meetingAsk", default: true)
        static let meetingPreRoll = StoredSetting.bool("meetingPreRoll", default: true)
        static let mcpEnabled = StoredSetting.bool(MCPDefaults.enabledKey, default: false)
        static let mcpOffTools = StoredSetting.strings(MCPDefaults.offToolsKey)
        static let meetingKeepAudio = StoredSetting.bool("meetingKeepAudio", default: true)
        static let meetingLearnVoices = StoredSetting.bool("meetingLearnVoices", default: false)
        static let meetingAskBeforeTranscribing = StoredSetting.bool("meetingAskBeforeTranscribing", default: false)
        static let meetingLimit = StoredSetting.int("meetingLimit", default: 0)
        static let askClaude = StoredSetting.bool("askClaude", default: Updates.isDevBuild)
        static let askClaudeSystemPrompt = StoredSetting.string(MCPDefaults.systemPromptKey, default: "")
        static let meetingHooks = StoredSetting<[MeetingHook]>(
            load: { MeetingHook.stored(in: $0) }, save: { MeetingHook.store($0, in: $1) })
        static let askClaudePermissionMode = StoredSetting.string("askClaudePermissionMode", default: "auto")
        static let askClaudeFolder = StoredSetting.string("askClaudeFolder", default: FileManager.default.homeDirectoryForCurrentUser.path)
        static let askClaudeTools = StoredSetting.strings("askClaudeTools")
        static let askClaudeModel = StoredSetting.string("askClaudeModel", default: ClaudeRun.defaultModel)
        static let askClaudeOnCamera = StoredSetting.bool("askClaudeOnCamera", default: false)
        static let meetingCamera = StoredSetting.string("meetingCamera", default: "")
        static let recordRoomShortcut = StoredSetting<KeyCombo?>.optionalJSON("recordRoomShortcut")
        static let debugLogs = StoredSetting.bool("debugLogs", default: false)
    }
}

/// How one setting is read back from UserDefaults and saved there, under
/// its key. `load` gives the default when nothing is stored.
struct StoredSetting<Value>: Sendable {
    let load: @Sendable (UserDefaults) -> Value
    let save: @Sendable (Value, UserDefaults) -> Void
}

extension StoredSetting where Value == Bool {
    static func bool(_ key: String, default fallback: Bool) -> Self {
        Self(load: { $0.object(forKey: key) == nil ? fallback : $0.bool(forKey: key) }, save: { $1.set($0, forKey: key) })
    }
}

extension StoredSetting where Value == Int {
    static func int(_ key: String, default fallback: Int) -> Self {
        Self(load: { $0.object(forKey: key) == nil ? fallback : $0.integer(forKey: key) }, save: { $1.set($0, forKey: key) })
    }
}

extension StoredSetting where Value == String {
    static func string(_ key: String, default fallback: String) -> Self {
        Self(load: { $0.string(forKey: key) ?? fallback }, save: { $1.set($0, forKey: key) })
    }
}

extension StoredSetting where Value == String? {
    static func optionalString(_ key: String) -> Self {
        Self(load: { $0.string(forKey: key) }, save: { $1.set($0, forKey: key) })
    }
}

extension StoredSetting where Value == [String] {
    /// Nothing stored reads as no strings.
    static func strings(_ key: String) -> Self {
        Self(load: { $0.stringArray(forKey: key) ?? [] }, save: { $1.set($0, forKey: key) })
    }
}

extension StoredSetting where Value: RawRepresentable & Sendable, Value.RawValue == String {
    /// Stored as its raw value; one that no longer names a case reads as the default.
    static func raw(_ key: String, default fallback: Value) -> Self {
        Self(load: { $0.string(forKey: key).flatMap(Value.init) ?? fallback }, save: { $1.set($0.rawValue, forKey: key) })
    }
}

extension StoredSetting {
    static func optionalRaw<Case: RawRepresentable>(_ key: String) -> Self where Value == Case?, Case.RawValue == String {
        Self(load: { $0.string(forKey: key).flatMap(Case.init) }, save: { $1.set($0?.rawValue, forKey: key) })
    }

    /// Stored as its raw values, sorted; values that no longer name a case are dropped.
    static func rawSet<Case: RawRepresentable>(_ key: String) -> Self where Value == Set<Case>, Case.RawValue == String {
        Self(load: { Set(($0.stringArray(forKey: key) ?? []).compactMap(Case.init)) }, save: { $1.set($0.map(\.rawValue).sorted(), forKey: key) })
    }

    /// Nil removes the key.
    static func optionalJSON<Wrapped: Codable>(_ key: String) -> Self where Value == Wrapped? {
        Self(
            load: { $0.data(forKey: key).flatMap { try? JSONDecoder().decode(Wrapped.self, from: $0) } },
            save: { $1.set($0.flatMap { try? JSONEncoder().encode($0) }, forKey: key) }
        )
    }
}

extension StoredSetting where Value: Codable & Sendable {
    /// Stored as JSON data; data that does not decode reads as the default.
    static func json(_ key: String, default fallback: Value) -> Self {
        Self(
            load: { $0.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? fallback },
            save: { $1.set(try? JSONEncoder().encode($0), forKey: key) }
        )
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
    static let privacyURL = websiteURL.appending(path: "privacy")
    static let contactEmail = "hello@typeme.it"
    static let contactURL = URL(string: "mailto:\(contactEmail)")!
    /// The GitHub release page for a version, linked from the about row.
    static func releaseURL(_ version: String) -> String { "https://github.com/typemeit/typemeit/releases/tag/v\(version)" }
    static let holdThresholdMs = 300
    /// How often a held hotkey's modifiers are checked for release.
    static let holdPollMs = 20.0
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
    /// An unmute that does not take is tried this many times, this far
    /// apart: long enough to outlast a Bluetooth headset leaving its
    /// headset profile, short enough not to undo a mute the user sets
    /// straight after a dictation.
    static let unmuteTries = 12
    static let unmuteRetryInterval: TimeInterval = 0.25
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
