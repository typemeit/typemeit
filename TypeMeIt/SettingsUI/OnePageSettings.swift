import FoundationModels
import SwiftUI

/// A group on the settings page, in the order the page lists them.
enum SettingsSection: String, CaseIterable {
    case cloud, typing, cleanUp = "clean-up", meetings, shortcuts, microphone, onThisMac = "on this mac", app, about
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
        case 0: "everything · never delete"
        case ..<0: "nothing · never keep"
        default: "the last \(counted(limit, noun))"
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
/// opening in place to its rows, one group at a time. A blocked setting says
/// why under its label, with the way to unblock it beside its switch.
struct OnePageSettings: View {
    @Binding var open: SettingsSection?
    @State private var settings = Settings.shared
    @State private var store = Store.shared
    @State private var meetings = MeetingStore.shared
    @State private var coordinator = MeetingCoordinator.shared
    @State private var updates = Updates.shared
    @State private var devices = AudioCapture.inputDevices()
    @State private var availability = PostProcessor.availability
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    /// Apple Intelligence and Screen Recording are switched in System
    /// Settings, not in the app, so both are re-read while the window is up.
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SettingsSection.allCases, id: \.self) { section in
                        SquareGroup(title: section.rawValue, summary: summary(section), open: binding(section)) {
                            rows(section)
                        }
                        .id(section)
                    }
                }
                .overlay(alignment: .bottom) { SquareRule() }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.top, 26)
                .padding(.leading, 40)
                .padding(.trailing, 48)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { if let open { proxy.scrollTo(open, anchor: .top) } }
        }
        .onAppear { availability = PostProcessor.availability; devices = AudioCapture.inputDevices() }
        .onReceive(poll) { _ in
            availability = PostProcessor.availability
            screenGranted = CGPreflightScreenCaptureAccess()
        }
    }

    private func binding(_ section: SettingsSection) -> Binding<Bool> {
        Binding(get: { open == section }, set: { on in
            if on { open = section } else if open == section { open = nil }
        })
    }

    @ViewBuilder private func rows(_ section: SettingsSection) -> some View {
        switch section {
        case .cloud: cloud
        case .typing: typing
        case .cleanUp: cleanUp
        case .meetings: meetingRows
        case .shortcuts: shortcuts
        case .microphone: microphone
        case .onThisMac: onThisMac
        case .app: app
        case .about: about
        }
    }

    // MARK: Groups

    private var cloud: some View {
        SquareRows {
            VStack(alignment: .leading, spacing: 6) {
                Text("colour").font(Square.mono(13)).foregroundStyle(DesignTokens.Colors.ink)
                SquareCloudPalette(selection: cloudChoice, screenRecordingAllowed: screenGranted) {
                    NSWorkspace.shared.open(SecureInput.screenRecordingSettingsURL)
                }
            }
            .padding(.top, 11)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { SquareRule() }
            SquareSettingsRow(label: "position") {
                SquareChoice(selection: $settings.cloudPosition, options: CloudPosition.allCases) { $0.label }
            }
            SquareSettingsRow(label: "sounds") { toggle("sounds", $settings.audioFeedback) }
        }
    }

    private var typing: some View {
        SquareRows {
            SquareSettingsRow(label: "space after typing") { toggle("space after typing", $settings.appendTrailingSpace) }
            SquareSettingsRow(label: "offer to copy when no text box is focused") { toggle("offer to copy", $settings.copyPromptEnabled) }
            SquareSettingsRow(label: "key after typing") { toggle("key after typing", $settings.autoSubmit) }
            if settings.autoSubmit {
                SquareSettingsRow(label: "key") {
                    SquareMenu(selection: $settings.autoSubmitKey, options: AutoSubmitKey.allCases, label: { $0.label }, minWidth: 180)
                }
            }
        }
    }

    private var cleanUp: some View {
        SquareRows {
            SquareSettingsRow(label: "clean up", caption: cleanUpBlocked) {
                HStack(spacing: 8) {
                    if case .unavailable(.appleIntelligenceNotEnabled) = availability {
                        systemSettings(SecureInput.appleIntelligenceSettingsURL)
                    }
                    toggle("clean up", $settings.postProcessingEnabled).disabled(!modelAvailable)
                }
            }
            SquareSettingsRow(label: "read the screen for names and terms", caption: screenBlocked ? "needs screen recording permissions" : nil) {
                HStack(spacing: 8) {
                    if screenBlocked { systemSettings(SecureInput.screenRecordingSettingsURL) }
                    toggle("read the screen for names and terms", screenContext)
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
            SquareSettingsRow(label: "record meetings", help: "a call is detected when another app opens the microphone. the last two minutes are held in memory so a meeting does not start late, and are thrown away unless you say record.") {
                SquareChoice(selection: $settings.meetingAsk, options: [true, false]) { $0 ? "ask" : "never" }
            }
            if !settings.meetingNeverAsk.isEmpty {
                SquareSettingsRow(label: "never ask for") {
                    FlowLayout(spacing: 6) {
                        ForEach(settings.meetingNeverAsk, id: \.self) { bundleID in
                            SquareChip(text: OnePageSettings.appName(for: bundleID).lowercased()) {
                                settings.meetingNeverAsk.removeAll { $0 == bundleID }
                            }
                        }
                    }
                    .frame(maxWidth: 300, alignment: .trailing)
                }
            }
            SquareSettingsRow(label: "record the room") { SquareShortcutRecorder(combo: $settings.recordRoomShortcut) }
            SquareSettingsRow(label: "ask before transcribing", help: "\(counted(Fixed.meetingTranscribeAskSeconds, "second")) to choose later") {
                toggle("ask before transcribing", $settings.meetingAskBeforeTranscribing)
            }
            SquareSettingsRow(label: "mcp", caption: MCPSetup.translocated ? "move type me it to applications first" : "lets assistants, including cloud ones, read your meetings") {
                toggle("mcp", $settings.meetingsMCP).disabled(MCPSetup.translocated)
            } below: {
                if settings.meetingsMCP, !MCPSetup.translocated { MCPConnect() }
            }
            SquareSettingsRow(label: "system audio", caption: systemAudioCaption) {
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

    private var shortcuts: some View {
        SquareRows {
            SquareSettingsRow(label: "hold to talk") { SquareKeycap("fn") }
            SquareSettingsRow(label: "pin", help: "fn again to finish") { SquareKeycap("space") }
            SquareSettingsRow(label: "cancel") { SquareKeycap("esc") }
            SquareSettingsRow(label: "copy last transcript") { SquareShortcutRecorder(combo: $settings.copyLastShortcut) }
        }
    }

    private var microphone: some View {
        SquareRows {
            SquareSettingsRow(label: "microphone") {
                SquareMenu(selection: microphoneID, options: [""] + devices.map(\.id), label: microphoneName, minWidth: 230)
            }
            SquareSettingsRow(label: "mute audio") { toggle("mute audio", $settings.muteWhileRecording) }
            SquareSettingsRow(label: "pause audio") { toggle("pause audio", $settings.pauseWhileRecording) }
        }
        .onAppear { devices = AudioCapture.inputDevices() }
    }

    private var onThisMac: some View {
        SquareRows {
            SquareSubhead(text: "dictations", trailing: store.history.count.formatted(), first: true)
            SquareSettingsRow(label: "keep") {
                SquareMenu(selection: historyLimit, options: KeepLimit.dictations.options, label: KeepLimit.dictations.label, minWidth: 230)
            }
            SquareSettingsRow(label: "keep the audio", help: "deleted along with the dictation") {
                toggle("keep the dictations' audio", $settings.keepRecordings).disabled(settings.historyLimit < 0)
            }
            SquareSubhead(text: "meetings", trailing: [meetings.meetings.count.formatted(), meetingsUsage].compactMap { $0 }.joined(separator: " · "))
            SquareSettingsRow(label: "keep") {
                SquareMenu(selection: meetingLimit, options: KeepLimit.meetings.options, label: KeepLimit.meetings.label, minWidth: 230)
            }
            SquareSettingsRow(label: "keep the audio", help: "deleted along with the meeting") {
                toggle("keep the meetings' audio", $settings.meetingKeepAudio)
            }
            SquareSettingsRow(label: "meetings folder", caption: folderPath) {
                Button("open") { NSWorkspace.shared.open(meetings.publishedRoot) }
                    .buttonStyle(SquareButtonStyle())
                    .disabled(!meetings.folderAvailable)
            }
        }
    }

    private var app: some View {
        SquareRows {
            SquareSettingsRow(label: "open at login") {
                toggle("open at login", Binding(get: { settings.launchAtLogin }, set: {
                    settings.launchAtLogin = $0
                    AppDelegate.shared?.reconcileLaunchAtLogin()
                }))
            }
            if Sandbox.updatesItself {
                SquareSettingsRow(label: "auto update", help: "off, the version row still offers updates") {
                    toggle("auto update", Binding(get: { settings.autoUpdate }, set: {
                        settings.autoUpdate = $0
                        Updates.shared.preferencesChanged()
                    }))
                    .disabled(Updates.isDevBuild)
                }
                if settings.autoUpdate {
                    SquareSettingsRow(label: "ask before updating", help: "restarts itself when idle when turned off") {
                        toggle("ask before updating", Binding(get: { settings.askBeforeUpdating }, set: {
                            settings.askBeforeUpdating = $0
                            Updates.shared.preferencesChanged()
                        }))
                        .disabled(Updates.isDevBuild)
                    }
                }
            }
            SquareSettingsRow(label: "appearance", help: "both the app window and the cloud") {
                SquareMenu(selection: Binding(get: { settings.appearance }, set: {
                    settings.appearance = $0
                    AppDelegate.shared?.applyAppearance()
                }), options: Appearance.allCases, label: { $0.label }, minWidth: 140)
            }
            SquareSettingsRow(label: "debug logs", help: "what each dictation and paste did, in a file") {
                toggle("debug logs", $settings.debugLogs)
            }
            if settings.debugLogs {
                SquareSettingsRow(label: "log file", help: DebugLog.displayPath) {
                    HStack(spacing: 8) {
                        Button("show") { DebugLog.reveal() }.buttonStyle(SquareButtonStyle())
                        Button("delete") { DebugLog.delete() }.buttonStyle(SquareButtonStyle())
                    }
                }
            }
        }
    }

    private var about: some View {
        SquareRows {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    SquareLink(title: "version \(AppVersion.current)", size: 13) {
                        if let url = URL(string: Fixed.releaseURL(AppVersion.current)) { NSWorkspace.shared.open(url) }
                    }
                    Group {
                        Text(OnePageSettings.linked([("parakeet 0.6b", "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2"),
                                                     (" · ", nil),
                                                     ("apple intelligence", "https://www.apple.com/apple-intelligence/")]))
                        // The speaker model's weights are CC-BY-4.0: attribution is owed (docs/meetings.md 8.2).
                        Text(OnePageSettings.linked([("speakers: pyannote community-1, wespeaker and vbx (but speech@fit), converted to core ml by fluid inference · ", nil),
                                                     ("cc-by-4.0", "https://creativecommons.org/licenses/by/4.0")]))
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
            SquareSettingsRow(label: "contact") {
                Button(Fixed.contactEmail) { NSWorkspace.shared.open(Fixed.contactURL) }.buttonStyle(SquareButtonStyle())
            }
        }
    }

    // MARK: Each group's line

    private func summary(_ section: SettingsSection) -> String {
        switch section {
        case .cloud:
            let colour = settings.cloudChoice == .matchBehind ? "matches what is behind it" : settings.cloudChoice.label
            return OnePageSettings.join(colour, settings.cloudPosition.label, settings.audioFeedback ? "sounds on" : "sounds off")
        case .typing:
            return OnePageSettings.join(settings.appendTrailingSpace ? "space after" : "no space after",
                                        settings.copyPromptEnabled ? "offers to copy" : nil,
                                        settings.autoSubmit ? "then \(settings.autoSubmitKey.label)" : nil)
        case .cleanUp:
            guard modelAvailable else { return "needs apple intelligence" }
            guard settings.postProcessingEnabled else { return "off" }
            return OnePageSettings.join("on", settings.screenContextEnabled ? "reads the screen" : nil,
                                        "\(settings.writingStyles.count) of \(counted(WritingStyle.allCases.count, "style"))")
        case .meetings:
            return OnePageSettings.join(settings.meetingAsk ? "asks" : "never asks",
                                        settings.recordRoomShortcut.map { "room \($0.caps.joined())" } ?? "no room shortcut",
                                        settings.meetingsMCP ? "mcp on" : nil)
        case .shortcuts:
            return OnePageSettings.join("fn", "space", "esc", settings.copyLastShortcut?.caps.joined())
        case .microphone:
            return OnePageSettings.join(microphoneName(settings.microphoneUID ?? ""),
                                        settings.muteWhileRecording ? "mutes audio" : settings.pauseWhileRecording ? "pauses audio" : nil)
        case .onThisMac:
            let keeps = [KeepLimit.dictations.summary(settings.historyLimit), KeepLimit.meetings.summary(settings.meetingLimit)].compactMap { $0 }
            return OnePageSettings.join(keeps.isEmpty ? "keeps everything" : keeps.joined(separator: " · "),
                                        meetingsUsage.map { "meetings use \($0)" })
        case .app:
            return OnePageSettings.join(settings.launchAtLogin ? "opens at login" : nil,
                                        Sandbox.updatesItself && settings.autoUpdate ? "updates itself" : nil,
                                        settings.appearance == .system ? nil : settings.appearance.label)
        case .about:
            return OnePageSettings.join(AppVersion.current, updateSummary)
        }
    }

    private static func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Rows' parts

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
            if choice == .matchBehind, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
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
        case .deviceNotEligible: return "this mac cannot run apple intelligence"
        case .appleIntelligenceNotEnabled: return "apple intelligence is off - turn it on in system settings to clean up and learn from corrections"
        case .modelNotReady: return "apple intelligence is still downloading - try again in a few minutes"
        @unknown default: return "apple intelligence is not available right now"
        }
    }

    /// The chosen microphone's id, "" for the system default.
    private var microphoneID: Binding<String> {
        Binding(get: { settings.microphoneUID ?? "" }, set: { settings.microphoneUID = $0.isEmpty ? nil : $0 })
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

    private var folderPath: String {
        guard meetings.folderAvailable else { return "unavailable" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = meetings.publishedRoot.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var systemAudioStatus: String {
        switch coordinator.systemAudioTest {
        case .notTested: "not tested"
        case .testing: "testing…"
        case .working: "working"
        case .silent: "silent"
        }
    }

    private var systemAudioCaption: String {
        let what = "plays a short sound to check type me it can hear other apps"
        return coordinator.systemAudioTest == .silent ? "quit and reopen after granting\n\(what)" : what
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
        if Updates.isDevBuild { return "dev build · never updates" }
        if !Sandbox.updatesItself { return "updated by the app store" }
        switch updates.state {
        case .checking: return "checking…"
        case .upToDate: return "the latest version"
        case .downloading(let v): return "downloading \(v)…"
        case .available(let v), .readyToInstall(let v): return "\(v) available"
        case .installing: return "installing…"
        case .unreachable: return "can't reach the update server"
        case .downloadFailed(let v): return "couldn't download \(v) · trying again later"
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

    /// The app's name for a never-ask chip, from its bundle on disk; the
    /// bundle id itself when the app is gone.
    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
