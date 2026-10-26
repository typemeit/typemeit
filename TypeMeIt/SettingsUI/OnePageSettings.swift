import AVFoundation
import FoundationModels
import SwiftUI

/// A group on the settings page, in the order the page lists them.
enum SettingsSection: String, CaseIterable {
    case dictation, cleanUp = "clean-up", meetings, assistant = "ai assistant", onThisMac = "on this mac", app

    /// What the group is for, over its rows when it opens.
    var blurb: String? {
        switch self {
        case .onThisMac: Sandbox.hasMeetings ? "dictations, meetings and their audio are stored on this mac and nowhere else." : "dictations and their audio are stored on this mac and nowhere else."
        default: nil
        }
    }

    /// The groups this build shows.
    static var available: [SettingsSection] { allCases.filter { $0 != .meetings || Sandbox.hasMeetings } }
}

/// How many dictations or meetings are kept: the last n, everything (0),
/// or, for dictations, nothing at all (-1).
struct KeepLimit {
    let noun: String
    let options: [Int]

    static let dictations = KeepLimit(noun: "dictation", options: [100, 250, 500, 1000, 2000, 5000, 0, -1])
    static let meetings = KeepLimit(noun: "meeting", options: [50, 100, 250, 500, 0])

    /// As the keep menu lists it.
    func label(_ limit: Int) -> String {
        switch limit {
        case 0: "everything"
        case ..<0: "nothing"
        default: "last \(limit.formatted())"
        }
    }

    /// As a page's title says it, after the page's own count.
    func status(_ limit: Int) -> String {
        switch limit {
        case 0: "keeps everything"
        case ..<0: "keeps nothing"
        default: "keeps the last \(limit.formatted())"
        }
    }

    /// As the group's line says it; nil when everything is kept.
    func summary(_ limit: Int) -> String? {
        switch limit {
        case 0: nil
        case ..<0: "keeps no \(noun)s"
        default: "keeps the last \(counted(limit, noun))"
        }
    }
}

/// Every setting on one page: each group one line saying what it is set to,
/// opening in place to its rows. Groups open and close on their own, so a
/// click moves only what is under the group. A blocked setting says why
/// under its label, with the way to unblock it beside its switch.
struct OnePageSettings: View {
    @Binding var open: Set<SettingsSection>
    /// A group a page's link asked for, scrolled to once.
    @Binding var reveal: SettingsSection?
    @State private var settings = Settings.shared
    @State private var store = Store.shared
    @State private var meetings = MeetingStore.shared
    @State private var coordinator = MeetingCoordinator.shared
    @State private var updates = Updates.shared
    /// Read from the CLI when the ask claude rows first show; nil until then.
    @State private var claudeModels: [ClaudeModels.Model]?
    @State private var camera = CameraFeed.shared
    @State private var cameraInstaller = CameraInstaller.shared
    @State private var cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var settingUpCamera = false
    @State private var removingCamera = false
    /// A new hook's name, typed before it is added.
    @State private var hookName = ""
    @State private var claudeCheck = ClaudeCheck.shared
    @State private var checkDetailsOpen = false
    @State private var devices = AudioCapture.inputDevices()
    @State private var availability = PostProcessor.availability
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var deletingDictations = false
    @State private var deletingMeetings = false
    @State private var checkingAudio = false
    @State private var deletingLog = false
    @State private var forgettingVoices = false
    /// The meetings whose voices are learned, and how many of them have no
    /// audio to learn them from again, counted when "learn voices" goes off.
    @State private var voicesToForget = (meetings: 0, withoutAudio: 0)
    /// Apple Intelligence and Screen Recording are switched in System
    /// Settings, not in the app, so both are re-read while the window is up.
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SettingsSection.available, id: \.self) { section in
                        SquareGroup(title: section.rawValue, summary: summary(section), blurb: section.blurb, open: binding(section)) {
                            rows(section)
                        }
                        .id(section)
                    }
                }
                .overlay(alignment: .bottom) { SquareRule() }
                .padding(.top, 26)
                .padding(.leading, 40)
                .padding(.trailing, 48)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                guard let reveal else { return }
                proxy.scrollTo(reveal, anchor: .top)
                self.reveal = nil
            }
        }
        .onAppear { availability = PostProcessor.availability; devices = AudioCapture.inputDevices() }
        .onReceive(poll) { _ in
            availability = PostProcessor.availability
            screenGranted = CGPreflightScreenCaptureAccess()
            cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
            let pickedUID = settings.microphoneUID
            if settings.connectedMicrophoneUID() != pickedUID { devices = AudioCapture.inputDevices() }
        }
    }

    private func binding(_ section: SettingsSection) -> Binding<Bool> {
        Binding(get: { open.contains(section) }, set: { on in
            if on { open.insert(section) } else { open.remove(section) }
        })
    }

    @ViewBuilder private func rows(_ section: SettingsSection) -> some View {
        switch section {
        case .dictation: dictation
        case .cleanUp: cleanUp
        case .meetings: meetingRows
        case .assistant: assistant
        case .onThisMac: onThisMac
        case .app: app
        }
    }

    // MARK: Groups

    private var assistant: some View {
        SquareRows {
            SquareSubhead(text: "mcp", first: true,
                          blurb: "lets assistants on this mac, like claude code or claude desktop, read your meetings and dictations locally and add hooks.")
            SquareSettingsRow(label: "server", help: "lets assistants read your meetings and dictations locally · a cloud assistant sends what it reads to its servers · try asking claude code \u{201C}what was my last meeting about?\u{201D}",
                              caption: MCPSetup.translocated ? "move to applications first" : nil) {
                toggle("mcp server", $settings.mcpEnabled).disabled(MCPSetup.translocated)
            } below: {
                if settings.mcpEnabled, !MCPSetup.translocated {
                    VStack(alignment: .leading, spacing: 10) {
                        if ClaudeRun.isAvailable { MCPAddToClaudeCode() }
                        MCPToolList()
                    }
                }
            }
            SquareSubhead(text: "everywhere",
                          blurb: "claude code answers questions you ask in a call or a dictation, and runs your hooks on a meeting once it ends, using your account and mcp servers. each one sends the call's transcript to anthropic.")
            if ClaudeRun.isAvailable {
                SquareSettingsRow(label: "ask", help: OnePageSettings.askHelp) {
                    toggle("ask", checkedOn(get: { settings.askClaude }, set: { settings.askClaude = $0 }))
                }
                if showsClaudeRows { claudeRows }
            } else if !Sandbox.isActive {
                SquareSettingsRow(label: "ask", help: OnePageSettings.askHelp, caption: "needs claude code") {
                    HStack(spacing: 10) {
                        Button("install") { NSWorkspace.shared.open(ClaudeRun.installPage) }.buttonStyle(SquareButtonStyle())
                        toggle("ask", .constant(false)).disabled(true)
                    }
                }
            }
            if ClaudeRun.isAvailable {
                SquareSubhead(text: "meetings")
                meetingAskRows
            }
        }
    }

    private static let askHelp = "ask from the menu bar, or say \"claude, …?\" or \"tmi, …?\" in a call or a dictation · the answer is kept with the meeting"

    /// How Claude Code answers, wherever it is asked.
    @ViewBuilder private var claudeRows: some View {
        SquareSettingsRow(label: "folder", help: "claude code loads this folder's project settings and mcp servers", caption: claudeFolderPath) {
            Button("change") { chooseClaudeFolder() }.buttonStyle(SquareButtonStyle())
        }
        SquareSettingsRow(label: "model", help: "the models claude code offers your account · in auto mode only those that support it", caption: claudeModelCaption) {
            SquareMenu(selection: $settings.askClaudeModel, options: claudeModelOptions, label: claudeModelLabel, minWidth: 230)
        }
        .task { if claudeModels == nil { claudeModels = await ClaudeModels.load() } }
        SquareSettingsRow(label: "permissions", help: "what claude code may do without asking · anyone in the meeting can speak into the transcript claude reads",
                          caption: ClaudeRun.permissionModes.first { $0.mode == settings.askClaudePermissionMode }?.caption) {
            SquareMenu(selection: $settings.askClaudePermissionMode, options: ClaudeRun.permissionModes.map(\.mode), label: { $0 }, minWidth: 230)
        }
        SquareSettingsRow(label: "system prompt", help: "added to claude's system prompt on every ask") {
            EmptyView()
        } below: {
            promptEditor($settings.askClaudeSystemPrompt)
        }
        SquareSettingsRow(label: "claude code", help: "checks claude code runs the way ask and hooks need · runs when you turn either on, change these settings or claude code updates · if it fails, what you turned on goes back off · use installs the last version that worked, and claude code updates itself again unless DISABLE_AUTOUPDATER is 1 under env in ~/.claude/settings.json",
                          caption: ClaudeCheck.caption(claudeCheck.status, lastPassed: claudeCheck.lastPassed)) {
            if let rollback = claudeCheck.rollback {
                Button("use \(rollback)") { claudeCheck.rollBack(to: rollback) }.buttonStyle(SquareButtonStyle(kind: .primary))
            } else {
                Button("check") { claudeCheck.run() }
                    .buttonStyle(SquareButtonStyle())
                    .disabled(checkBusy)
            }
        } below: {
            if case .failed = claudeCheck.status, !claudeCheck.runs.isEmpty { checkDetails }
        }
        .onChange(of: ClaudeCheck.conditions) { _, _ in
            if ClaudeCheck.inUse { claudeCheck.run() }
        }
    }

    private var checkBusy: Bool {
        switch claudeCheck.status {
        case .checking, .installing: true
        default: false
        }
    }

    /// Where a failed check's runs went other than asked, and the runs themselves, folded.
    private var checkDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { checkDetailsOpen.toggle() } label: {
                HStack(spacing: 6) {
                    SquareIcon("akar-chevron-down", size: 9).rotationEffect(.degrees(checkDetailsOpen ? 0 : -90))
                    Text("details").font(Square.mono(12))
                }
                .foregroundStyle(DesignTokens.Colors.ink3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if checkDetailsOpen {
                if case .failed(_, let problems, _) = claudeCheck.status {
                    ForEach(problems, id: \.self) { problem in
                        Text(problem).font(Square.mono(12)).foregroundStyle(DesignTokens.Colors.ink2)
                    }
                }
                ForEach(claudeCheck.runs, id: \.id) { run in
                    ClaudeRunOutput(id: run.id, kept: run.answer.map { .init(prompt: run.prompt, answer: $0.text, failed: $0.failed, sessionID: $0.sessionID) })
                }
            }
        }
    }

    /// Ask's rows, which hooks run with too, and the check's result while it runs or has failed.
    private var showsClaudeRows: Bool {
        guard !settings.askClaude, !settings.meetingHooks.contains(where: \.on) else { return true }
        switch claudeCheck.status {
        case .checking, .installing, .failed: return true
        case .unchecked, .passed: return false
        }
    }

    /// A switch for ask or a hook that checks Claude Code as it goes on, and
    /// goes back off if the check fails.
    private func checkedOn(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: { on in
            set(on)
            if on { claudeCheck.ensure { passed in if !passed { set(false) } } }
        })
    }

    /// While ask is on, the camera; and hooks, which only need Claude Code.
    @ViewBuilder private var meetingAskRows: some View {
        if settings.askClaude {
            SquareSettingsRow(label: "on camera", help: "shows the cloud and claude's answer in your video while a meeting records · pick type me it as the camera in your meeting app",
                              caption: onCameraCaption) {
                HStack(spacing: 10) {
                    if settings.askClaudeOnCamera, !cameraReady {
                        Button("finish") { settingUpCamera = true }.buttonStyle(SquareButtonStyle())
                    }
                    toggle("on camera", $settings.askClaudeOnCamera)
                }
            }
            .onChange(of: settings.askClaudeOnCamera) { _, on in if on, !cameraReady { settingUpCamera = true } }
            .sheet(isPresented: $settingUpCamera) { CameraSetupView { settingUpCamera = false } }
            if camera.installed {
                SquareSettingsRow(label: "camera", help: "the camera type me it shows") {
                    SquareMenu(selection: $settings.meetingCamera, options: cameraOptions, label: cameraLabel, minWidth: 230)
                }
                .onChange(of: settings.meetingCamera) { camera.cameraChanged() }
                if CameraInstaller.canAdd {
                    SquareSettingsRow(label: "remove camera", help: "meeting apps stop listing type me it") {
                        Button("remove") { removingCamera = true }
                            .buttonStyle(SquareButtonStyle())
                            .squareConfirmDelete(isPresented: $removingCamera, title: "remove the type me it camera?",
                                                 detail: "add it again from on camera", confirm: "remove") {
                                settings.askClaudeOnCamera = false
                                cameraInstaller.remove()
                            }
                    }
                }
            }
        }
        SquareSettingsRow(label: "hooks", help: "prompts claude runs on a finished meeting when you press run hooks · results show on the meeting page · ones added over mcp start off") {
            HStack(spacing: 8) {
                SquareField(placeholder: "name a new hook", text: $hookName, onSubmit: addHook).frame(width: 200)
                Button("add", action: addHook)
                    .buttonStyle(SquareButtonStyle())
                    .disabled(hookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        ForEach($settings.meetingHooks) { $hook in
            SquareSettingsRow(label: hook.name) {
                HStack(spacing: 10) {
                    Button {
                        // Read through the binding before the array changes: reading it
                        // inside removeAll is a second access to the same array.
                        let removedID = hook.id
                        settings.meetingHooks.removeAll { $0.id == removedID }
                    } label: { SquareIcon("akar-trash-can", size: 14) }
                        .buttonStyle(SquareIconButtonStyle())
                        .help("remove")
                        .accessibilityLabel("remove \(hook.name)")
                    toggle(hook.name, hookSwitch(hook.id))
                }
            } below: {
                promptEditor($hook.prompt, placeholder: "what claude should do with the meeting")
            }
        }
    }

    private var dictation: some View {
        SquareRows {
            SquareSubhead(text: "recording", first: true)
            SquareSettingsRow(label: "microphone", help: "meetings record your side from it too") {
                SquareMenu(selection: microphoneID, options: [""] + devices.map(\.id), label: microphoneName, minWidth: 230)
            }
            SquareSettingsRow(label: "mute audio", help: "mutes your speakers while you dictate · not during meetings") { toggle("mute audio", $settings.muteWhileRecording) }
            SquareSettingsRow(label: "pause audio", help: "pauses music or video while you dictate · not during meetings") { toggle("pause audio", $settings.pauseWhileRecording) }
            if !Sandbox.watchesFn {
                SquareSettingsRow(label: "hold to talk") {
                    SquareShortcutRecorder(combo: Binding(get: { settings.dictationShortcut }, set: { if let c = $0 { settings.dictationShortcut = c } }), clearable: false)
                }
                SquareSettingsRow(label: "pin", help: "\(settings.dictationShortcut.inline) again to finish") { SquareKeycap("space") }
            }
            SquareSettingsRow(label: "check audio", help: "tests your mic and speakers · writes the results to the debug log and your clipboard · plays a short tone · includes device and app names") {
                Button(checkingAudio ? "running" : "run") {
                    checkingAudio = true
                    Task {
                        await AudioCheck.run()
                        checkingAudio = false
                    }
                }
                .buttonStyle(SquareButtonStyle())
                .disabled(checkingAudio)
            }
            SquareSubhead(text: "cloud")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("colour").font(Square.mono(13)).foregroundStyle(DesignTokens.Colors.ink)
                    SquareHelp(text: "dynamic reads the screen behind the cloud to pick white or black · needs screen recording")
                }
                SquareCloudPalette(selection: cloudChoice, screenRecordingAllowed: screenGranted) {
                    NSWorkspace.shared.open(SecureInput.screenRecordingSettingsURL)
                }
            }
            .padding(.top, 11)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { SquareRule() }
            SquareSettingsRow(label: "position", caption: settings.cloudPosition.label) {
                SquareScreenPicker(selection: $settings.cloudPosition).padding(.vertical, 10)
            }
            SquareSettingsRow(label: "sounds", help: "a cue when you pin and when you stop · silent during meetings") { toggle("sounds", $settings.audioFeedback) }
        }
        .onAppear { devices = AudioCapture.inputDevices() }
    }

    private var cleanUp: some View {
        SquareRows {
            SquareSettingsRow(label: "clean up", help: "apple intelligence fixes punctuation and misheard words, on this mac · off: basic tidying only, no writing styles", caption: cleanUpBlocked) {
                HStack(spacing: 8) {
                    if case .unavailable(.appleIntelligenceNotEnabled) = availability {
                        systemSettings(SecureInput.appleIntelligenceSettingsURL)
                    }
                    toggle("clean up", $settings.postProcessingEnabled).disabled(!modelAvailable)
                }
            }
            SquareSettingsRow(label: "read the screen", help: "spells names and terms from the window you're typing into · stays on this mac", caption: screenBlocked ? "needs screen recording" : nil) {
                HStack(spacing: 8) {
                    if screenBlocked { systemSettings(SecureInput.screenRecordingSettingsURL) }
                    toggle("read the screen", screenContext)
                }
                .disabled(!settings.postProcessingEnabled)
            }
            SquareSubhead(text: "writing style", trailing: "\(settings.writingStyles.count) of \(WritingStyle.allCases.count)")
            ForEach(WritingStyle.allCases, id: \.self) { style in
                SquareSettingsRow(label: style.label, help: style.example) {
                    toggle(style.label, writingStyle(style)).disabled(!settings.postProcessingEnabled || !modelAvailable)
                }
            }
        }
    }

    private var meetingRows: some View {
        SquareRows {
            SquareSettingsRow(label: "record meetings", help: "asks to record when an app uses the mic and speakers · holds the last 2 minutes in memory, deleted unless you record · never: record from the menu") {
                SquareChoice(selection: $settings.meetingAsk, options: [true, false]) { $0 ? "ask" : "never" }
            }
            SquareSettingsRow(label: "record the room", help: "records the mic only, for people in the room · press again to stop") { SquareShortcutRecorder(combo: $settings.recordRoomShortcut) }
            SquareSettingsRow(label: "ask before transcribing", help: "after a meeting, \(counted(Fixed.meetingTranscribeAskSeconds, "second")) to put the transcript off · keeps the mac free for dictation") {
                toggle("ask before transcribing", $settings.meetingAskBeforeTranscribing)
            }
            SquareSettingsRow(label: "learn voices", help: "suggests names for numbered speakers from people you've named before · keeps voiceprints on this mac · off: deletes them") {
                toggle("learn voices", Binding(get: { settings.meetingLearnVoices }, set: { on in
                    guard !on else {
                        settings.meetingLearnVoices = true
                        meetings.learnVoices()
                        return
                    }
                    let learned = VoiceLibrary.learnedIDs()
                    let learnedMeetings = meetings.meetings.filter { learned.contains($0.id) }
                    voicesToForget = (learnedMeetings.count, learnedMeetings.filter(\.audioFiles.isEmpty).count)
                    if learnedMeetings.isEmpty { stopLearningVoices() } else { forgettingVoices = true }
                }))
                .squareConfirmDelete(isPresented: $forgettingVoices, title: "delete voiceprints from \(counted(voicesToForget.meetings, "meeting"))?",
                                     detail: voicesToForget.withoutAudio == 0 ? "on again relearns them from the audio"
                                         : "\(counted(voicesToForget.withoutAudio, "meeting")) have no audio to relearn from",
                                     delete: stopLearningVoices)
            }
            SquareSettingsRow(label: "system audio", help: "checks type me it can record the other side of calls",
                              caption: coordinator.systemAudioTest == .silent ? "reopen after granting" : nil) {
                HStack(spacing: 10) {
                    Text(systemAudioStatus).font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink2)
                    if coordinator.systemAudioTest == .silent { systemSettings(SecureInput.systemAudioSettingsURL) }
                    Button("test") { coordinator.testSystemAudio() }
                        .buttonStyle(SquareButtonStyle())
                        .disabled(coordinator.systemAudioTest == .testing || coordinator.recording != nil)
                }
            }
        }
    }


    private var onThisMac: some View {
        SquareRows {
            SquareSubhead(text: "dictations", trailing: store.history.count.formatted(), first: true)
            SquareSettingsRow(label: "keep", help: "starred dictations are always kept") {
                SquareMenu(selection: historyLimit, options: KeepLimit.dictations.options, label: KeepLimit.dictations.label, minWidth: 230)
            }
            SquareSettingsRow(label: "keep the audio", help: "replay dictations in history · off: new ones aren't saved") {
                toggle("keep the dictations' audio", $settings.keepRecordings).disabled(settings.historyLimit < 0)
            }
            SquareSettingsRow(label: "delete all") {
                deleteAll(store.history.count, "dictation", showing: $deletingDictations) { store.deleteAllHistory() }
            }
            if Sandbox.hasMeetings { meetingStorageRows }
        }
    }

    @ViewBuilder private var meetingStorageRows: some View {
        SquareSubhead(text: "meetings", trailing: [meetings.meetings.count.formatted(), meetingsUsage].compactMap { $0 }.joined(separator: " · "))
        SquareSettingsRow(label: "keep", help: "only transcribed meetings count") {
            SquareMenu(selection: meetingLimit, options: KeepLimit.meetings.options, label: KeepLimit.meetings.label, minWidth: 230)
        }
        SquareSettingsRow(label: "keep the audio", help: "replay meetings and relearn voices · off: deleted after transcribing") {
            toggle("keep the meetings' audio", $settings.meetingKeepAudio)
        }
        SquareSettingsRow(label: "delete all") {
            // A meeting still recording is left alone; it can be deleted once it stops.
            let ids = Set(meetings.meetings.map(\.id)).subtracting(coordinator.liveIDs)
            deleteAll(ids.count, "meeting", showing: $deletingMeetings) { meetings.delete(ids: ids) }
        }
        SquareSettingsRow(label: "folder", caption: folderPath) {
            Button("open") { NSWorkspace.shared.open(meetings.publishedRoot) }
                .buttonStyle(SquareButtonStyle())
                .disabled(!meetings.folderAvailable)
        }
    }

    private var app: some View {
        SquareRows {
            SquareSettingsRow(label: "appearance", help: "the window and the cloud") {
                SquareMenu(selection: Binding(get: { settings.appearance }, set: {
                    settings.appearance = $0
                    AppDelegate.shared?.applyAppearance()
                }), options: Appearance.allCases, label: { $0.label }, minWidth: 140)
            }
            SquareSettingsRow(label: "open at login") {
                toggle("open at login", Binding(get: { settings.launchAtLogin }, set: {
                    settings.launchAtLogin = $0
                    AppDelegate.shared?.reconcileLaunchAtLogin()
                }))
            }
            if Sandbox.updatesItself {
                SquareSettingsRow(label: "auto update", help: "checks hourly and downloads in the background · off: about still offers updates") {
                    toggle("auto update", Binding(get: { settings.autoUpdate }, set: {
                        settings.autoUpdate = $0
                        Updates.shared.preferencesChanged()
                    }))
                    .disabled(Updates.isDevBuild)
                }
                if settings.autoUpdate {
                    SquareSettingsRow(label: "ask before updating", help: "off: installs and restarts when you're not dictating or recording") {
                        toggle("ask before updating", Binding(get: { settings.askBeforeUpdating }, set: {
                            settings.askBeforeUpdating = $0
                            Updates.shared.preferencesChanged()
                        }))
                        .disabled(Updates.isDevBuild)
                    }
                }
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    SquareLink(title: "version \(AppVersion.current)", size: 13) {
                        if let url = URL(string: Fixed.releaseURL(AppVersion.current)) { NSWorkspace.shared.open(url) }
                    }
                    Group {
                        Text(OnePageSettings.linked([("parakeet ultra", "https://huggingface.co/FluidInference/parakeet-ultra-coreml"),
                                                     (" cc-by-4.0", "https://creativecommons.org/licenses/by/4.0"),
                                                     (" · ", nil),
                                                     ("apple intelligence", "https://www.apple.com/apple-intelligence/")]))
                        // The speaker models' weights are OpenMDW-1.1 and CC-BY-4.0: attribution is owed (docs/meetings.md 8.2).
                        Text(OnePageSettings.linked([("speakers: nvidia nemotron 3 diarization · ", nil),
                                                     ("openmdw-1.1", "https://openmdw.ai/license/"),
                                                     (" · pyannote community-1, wespeaker and vbx (but speech@fit) · ", nil),
                                                     ("cc-by-4.0", "https://creativecommons.org/licenses/by/4.0"),
                                                     (" · converted to core ml by fluid inference", nil)]))
                    }
                    .font(Square.sans(11.5))
                    .lineSpacing(2)
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .tint(DesignTokens.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                updateStatus
            }
            .frame(minHeight: 44)
            .overlay(alignment: .top) { SquareRule() }
            SquareSettingsRow(label: "website") {
                SquareLink(title: "typeme.it", size: 12) { NSWorkspace.shared.open(Fixed.websiteURL) }
            }
            // App Review wants the privacy policy reachable in the app (5.1.1(i)).
            if Sandbox.isStoreBuild {
                SquareSettingsRow(label: "privacy") {
                    SquareLink(title: "typeme.it/privacy", size: 12) { NSWorkspace.shared.open(Fixed.privacyURL) }
                }
            }
            SquareSettingsRow(label: "contact") {
                Button(Fixed.contactEmail) { NSWorkspace.shared.open(Fixed.contactURL) }.buttonStyle(SquareButtonStyle())
            }
            SquareSettingsRow(label: "debug logs", help: "records each dictation and paste for bug reports · includes app names and the start of transcripts") {
                toggle("debug logs", $settings.debugLogs)
            }
            if settings.debugLogs {
                SquareSettingsRow(label: "log file", caption: DebugLog.displayPath) {
                    HStack(spacing: 8) {
                        Button("show") { DebugLog.reveal() }.buttonStyle(SquareButtonStyle())
                        Button("delete") { deletingLog.toggle() }
                            .buttonStyle(SquareButtonStyle())
                            .squareConfirmDelete(isPresented: $deletingLog, title: "delete the log file?") { DebugLog.delete() }
                    }
                }
            }
        }
    }


    // MARK: Each group's line

    private func summary(_ section: SettingsSection) -> String {
        switch section {
        case .dictation:
            return OnePageSettings.join(Sandbox.watchesFn ? nil : settings.dictationShortcut.inline, microphoneName(settings.microphoneUID ?? ""),
                                        settings.muteWhileRecording ? "mutes audio" : settings.pauseWhileRecording ? "pauses audio" : nil,
                                        settings.cloudChoice.label, settings.cloudPosition.label, settings.audioFeedback ? "sounds on" : "sounds off")
        case .cleanUp:
            guard modelAvailable else { return "needs apple intelligence" }
            guard settings.postProcessingEnabled else { return "off" }
            return OnePageSettings.join("on", settings.screenContextEnabled ? "reads the screen" : nil,
                                        "\(settings.writingStyles.count) of \(counted(WritingStyle.allCases.count, "style"))")
        case .meetings:
            return OnePageSettings.join(settings.meetingAsk ? "asks" : "never asks",
                                        settings.recordRoomShortcut.map { "room \($0.caps.joined())" } ?? "no room shortcut",
                                        settings.meetingLearnVoices ? "learns voices" : nil)
        case .assistant:
            let ask: String? = if !ClaudeRun.isAvailable { Sandbox.isActive ? nil : "needs claude code" }
                else if settings.askClaude { OnePageSettings.join("claude code", claudeModelLabel(settings.askClaudeModel), settings.askClaudePermissionMode) }
                else { nil }
            let hooks = ClaudeRun.isAvailable && !settings.meetingHooks.isEmpty ? counted(settings.meetingHooks.count, "hook") : nil
            let assistantSummary = OnePageSettings.join(ask, hooks, settings.mcpEnabled ? "mcp on" : nil)
            return assistantSummary.isEmpty ? "off" : assistantSummary
        case .onThisMac:
            let meetingKeep = Sandbox.hasMeetings ? KeepLimit.meetings.summary(settings.meetingLimit) : nil
            let keeps = [KeepLimit.dictations.summary(settings.historyLimit), meetingKeep].compactMap { $0 }
            return OnePageSettings.join(keeps.isEmpty ? "keeps everything" : keeps.joined(separator: " · "),
                                        Sandbox.hasMeetings ? meetingsUsage.map { "meetings use \($0)" } : nil)
        case .app:
            return OnePageSettings.join(AppVersion.current, updateSummary, settings.launchAtLogin ? "opens at login" : nil,
                                        settings.appearance == .system ? nil : settings.appearance.label)
        }
    }

    private static func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Rows' parts

    /// The button that deletes every dictation or meeting, after asking.
    private func deleteAll(_ count: Int, _ noun: String, showing: Binding<Bool>, delete: @escaping () -> Void) -> some View {
        Button("delete") { showing.wrappedValue.toggle() }
            .buttonStyle(SquareButtonStyle())
            .disabled(count == 0)
            .squareConfirmDelete(isPresented: showing, title: "delete all \(counted(count, noun))?",
                                 detail: SquareDeleteConfirm.gone(count), confirm: "delete all", delete: delete)
    }

    /// Switches "learn voices" off and deletes what it learned.
    private func stopLearningVoices() {
        settings.meetingLearnVoices = false
        Task { await VoiceLibrary.shared.forgetAll() }
    }

    /// A prompt typed in over several lines, with what goes in it shown while empty.
    private func promptEditor(_ text: Binding<String>, placeholder: String? = nil) -> some View {
        TextEditor(text: text)
            .font(Square.sans(13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 72)
            .overlay(alignment: .topLeading) {
                if let placeholder, text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(Square.sans(13))
                        .foregroundStyle(DesignTokens.Colors.ink3)
                        .padding(.horizontal, 11)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ruleControl, lineWidth: DesignTokens.hairline))
    }

    private func addHook() {
        let name = hookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let hook = MeetingHook(name: name)
        settings.meetingHooks.append(hook)
        hookName = ""
        hookSwitch(hook.id).wrappedValue = true
    }

    /// A hook's switch, by id: the check that runs as it goes on can end after
    /// the list has changed.
    private func hookSwitch(_ id: UUID) -> Binding<Bool> {
        checkedOn(get: { settings.meetingHooks.first { $0.id == id }?.on ?? false }, set: { on in
            guard let index = settings.meetingHooks.firstIndex(where: { $0.id == id }) else { return }
            settings.meetingHooks[index].on = on
        })
    }

    private func toggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn).toggleStyle(SquareSwitchStyle()).labelsHidden()
    }

    private func systemSettings(_ url: URL) -> some View {
        Button("system settings") { NSWorkspace.shared.open(url) }.buttonStyle(SquareButtonStyle(small: true))
    }

    /// The cloud's colour as one choice. Matching what is behind it reads the
    /// screen, so choosing it asks for Screen Recording if it is not granted.
    private var cloudChoice: Binding<CloudChoice> {
        Binding(get: { settings.cloudChoice }, set: { choice in
            settings.cloudChoice = choice
            if choice == .dynamic, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            screenGranted = CGPreflightScreenCaptureAccess()
        })
    }

    private var screenContext: Binding<Bool> {
        Binding(get: { settings.screenContextEnabled }, set: { on in
            settings.screenContextEnabled = on
            if on, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            screenGranted = CGPreflightScreenCaptureAccess()
        })
    }

    private var screenBlocked: Bool { settings.screenContextEnabled && !screenGranted }

    private func writingStyle(_ style: WritingStyle) -> Binding<Bool> {
        Binding(get: { settings.writingStyles.contains(style) }, set: { on in
            if on { settings.writingStyles.insert(style) } else { settings.writingStyles.remove(style) }
        })
    }

    private var modelAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    /// Why clean-up cannot run right now, or nil when it can.
    private var cleanUpBlocked: String? {
        guard case .unavailable(let reason) = availability else { return nil }
        switch reason {
        case .deviceNotEligible: return "not supported on this mac"
        case .appleIntelligenceNotEnabled: return "apple intelligence is off"
        case .modelNotReady: return "apple intelligence is downloading"
        @unknown default: return "apple intelligence is unavailable"
        }
    }

    /// The chosen microphone's id, "" for the system default.
    private var microphoneID: Binding<String> {
        Binding(get: { settings.microphoneUID ?? "" }, set: { id in
            settings.microphoneUID = id.isEmpty ? nil : id
            settings.microphoneName = AudioCapture.deviceID(forUID: id).flatMap(MeetingCapture.device)?.name
        })
    }

    private func microphoneName(_ id: String) -> String {
        if id.isEmpty { return "system default" }
        return devices.first { $0.id == id }?.name.lowercased() ?? "not connected"
    }

    private var historyLimit: Binding<Int> {
        Binding(get: { settings.historyLimit }, set: { settings.historyLimit = $0; store.prune(limit: $0) })
    }

    private var meetingLimit: Binding<Int> {
        Binding(get: { settings.meetingLimit }, set: { settings.meetingLimit = $0; meetings.prune() })
    }

    private var meetingsUsage: String? {
        meetings.diskUsage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file).lowercased() }
    }

    /// What the menu offers: the CLI's list, and the saved choice even if the
    /// list has not loaded or no longer has it.
    private var claudeModelOptions: [String] {
        let listed = offeredModels.map(\.value)
        return listed.contains(settings.askClaudeModel) ? listed : [settings.askClaudeModel] + listed
    }

    /// Auto mode runs only on the models that support it.
    private var offeredModels: [ClaudeModels.Model] {
        let all = claudeModels ?? []
        return settings.askClaudePermissionMode == "auto" ? all.filter { $0.supportsAutoMode == true } : all
    }

    private func claudeModelLabel(_ value: String) -> String {
        claudeModels?.first { $0.value == value }?.displayName.lowercased() ?? value
    }

    private var claudeModelCaption: String {
        guard let claudeModels else { return "reading claude code's models…" }
        guard let model = claudeModels.first(where: { $0.value == settings.askClaudeModel }) else {
            return claudeModels.isEmpty ? "claude code listed no models" : "not offered by claude code any more"
        }
        if !offeredModels.contains(model) { return "doesn't run in auto mode" }
        return model.description.lowercased()
    }

    /// The Mac's default, then each camera; the saved one stays listed while it is unplugged.
    private var cameraOptions: [String] {
        let listed = camera.cameras.map(\.uniqueID)
        let saved = [settings.meetingCamera].filter { !$0.isEmpty && !listed.contains($0) }
        return [""] + saved + listed
    }

    private func cameraLabel(_ value: String) -> String {
        if value.isEmpty { return "default" }
        return camera.cameras.first { $0.uniqueID == value }?.localizedName.lowercased() ?? "unplugged camera"
    }

    /// Added, allowed and given the real camera; picking it in a meeting app is up to the user.
    private var cameraReady: Bool { camera.installed && cameraAccess == .authorized }

    /// What is left of setting up on camera, or that a meeting shows it.
    private var onCameraCaption: String? {
        guard settings.askClaudeOnCamera else { return nil }
        if !camera.installed {
            if !CameraInstaller.canAdd { return "dev build: add it with scripts/install-camera.sh" }
            if !CameraInstaller.inApplications { return "move to applications first" }
            switch cameraInstaller.status {
            case .adding: return "adding…"
            case .needsApproval: return "needs approval in system settings"
            case .failed(let reason): return reason
            default: return "not added"
            }
        }
        switch cameraAccess {
        case .authorized: return camera.watched ? "showing in a meeting" : "pick type me it in your meeting app"
        case .notDetermined: return "needs camera access"
        default: return "camera access is off"
        }
    }

    private var claudeFolderPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = settings.askClaudeFolder
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseClaudeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.askClaudeFolder, isDirectory: true)
        panel.prompt = "choose"
        if panel.runModal() == .OK, let url = panel.url { settings.askClaudeFolder = url.path }
    }

    private var folderPath: String {
        guard meetings.folderAvailable else { return "unavailable" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = meetings.publishedRoot.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var systemAudioStatus: String {
        switch coordinator.systemAudioTest {
        case .notTested: "untested"
        case .testing: "testing…"
        case .working: "working"
        case .silent: "silent"
        }
    }

    /// Where the update check got to. It runs again each time the window
    /// comes to the front; the only action is installing a version, which
    /// downloads it first when auto update is off.
    @ViewBuilder private var updateStatus: some View {
        if let version = installable {
            Button("install \(version)") { updates.install() }.buttonStyle(SquareButtonStyle())
        } else {
            Text(updateSummary).font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink2)
        }
    }

    /// A version the version row can install, when the app updates itself.
    private var installable: String? {
        guard Sandbox.updatesItself, !Updates.isDevBuild else { return nil }
        switch updates.state {
        case .available(let v), .readyToInstall(let v): return v
        default: return nil
        }
    }

    private var updateSummary: String {
        // Store first, so a dev build previewing the store says what the store build does.
        if !Sandbox.updatesItself { return "updated by the app store" }
        if Updates.isDevBuild { return "dev build · never updates" }
        switch updates.state {
        case .checking: return "checking…"
        case .upToDate: return "up to date"
        case .downloading(let v): return "downloading \(v)…"
        case .available(let v), .readyToInstall(let v): return "\(v) available"
        case .installing: return "installing…"
        case .unreachable: return "update server unreachable"
        case .downloadFailed: return "download failed · retrying"
        }
    }

    /// Text with some of its runs linked, underlined in ink-a32.
    private static func linked(_ runs: [(String, String?)]) -> AttributedString {
        runs.reduce(into: AttributedString()) { out, run in
            var part = AttributedString(run.0)
            if let link = run.1, let url = URL(string: link) {
                part.link = url
                part.underlineStyle = Text.LineStyle(pattern: .solid, color: DesignTokens.Colors.inkA32)
            }
            out += part
        }
    }
}
