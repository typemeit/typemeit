import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The meetings page (docs/meetings.md 7.11): the list by day, with what
/// is live above it and the keep, folder and system-audio rows under it.
struct MeetingsTab: View {
    @State private var store = MeetingStore.shared
    @State private var coordinator = MeetingCoordinator.shared
    @State private var settings = Settings.shared
    @State private var player = RecordingPlayer.shared
    @State private var appState = AppState.shared
    @State private var search = ""
    /// The meeting shown as its own page, or nil for the list.
    @State private var open: UUID?
    @State private var selected: Set<UUID> = []
    @State private var anchor: UUID?
    @State private var confirmDeleteAll = false
    @State private var renaming: UUID?
    @State private var renameText = ""
    /// Re-reads the clock for the recording row's elapsed time.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    private var filtered: [Meeting] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.meetings }
        return store.meetings.filter { m in
            m.title.lowercased().contains(q) || m.speakers.contains { $0.name.lowercased().contains(q) } || m.paragraphs.contains { $0.text.lowercased().contains(q) }
        }
    }

    private var groups: [(title: String, meetings: [Meeting])] {
        let cal = Calendar.current
        var out: [(String, [Meeting])] = []
        for m in filtered {
            let title: String
            if cal.isDateInToday(m.started) { title = "today" }
            else if cal.isDateInYesterday(m.started) { title = "yesterday" }
            else { title = m.started.formatted(.dateTime.day().month(.wide)).lowercased() }
            if let last = out.last, last.0 == title { out[out.count - 1].1.append(m) } else { out.append((title, [m])) }
        }
        return out
    }

    var body: some View {
        Group {
            if let id = open, let m = store.meeting(id) {
                page(m)
            } else {
                list
            }
        }
        .onAppear(perform: reveal)
        .onChange(of: appState.revealMeeting) { _, _ in reveal() }
        .onChange(of: store.meetings.map(\.id)) { _, ids in if let id = open, !ids.contains(id) { open = nil } }
    }

    private var list: some View {
        VStack(spacing: 0) {
            topBar
            if coordinator.recording != nil || coordinator.transcribing != nil || coordinator.importing != nil || coordinator.importFailure != nil {
                statusRow
                RowRule()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if groups.isEmpty {
                        Text(store.meetings.isEmpty ? "nothing yet" : "no matches")
                            .foregroundStyle(DesignTokens.Colors.ink2).frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    ForEach(groups, id: \.title) { group in
                        SettingsGroup(title: group.title) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(group.meetings.enumerated()), id: \.element.id) { i, m in
                                    row(m, last: i == group.meetings.count - 1).id(m.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                           let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                    }
                    coordinator.importRecordings(urls)
                }
                return true
            }
            RowRule()
            footer
        }
        .onReceive(clock) { now = $0 }
    }

    /// The pill's `show` opens the meeting it names.
    private func reveal() {
        guard let id = appState.revealMeeting else { return }
        appState.revealMeeting = nil
        open = id
    }

    // MARK: A meeting's page

    /// One meeting: a way back, its title and details, its actions, and the
    /// whole transcript with room to read it.
    private func page(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { open = nil } label: {
                    HStack(spacing: 5) {
                        Image("akar-chevron-down").resizable().frame(width: 10, height: 10).rotationEffect(.degrees(90))
                        Text("meetings")
                    }
                    .font(.system(size: 12).monospaced())
                    .padding(.horizontal, 7).padding(.vertical, 4)
                }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.cancelAction)
                Spacer()
                actions(m)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 6) {
                title(m, size: 17)
                HStack(spacing: 8) {
                    Text(m.started.formatted(.dateTime.day().month(.wide).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).lowercased())
                        .font(.system(size: 11).monospaced()).foregroundStyle(DesignTokens.Colors.ink2)
                    telemetry(m)
                }
                chips(m)
            }
            .padding(.horizontal, 20).padding(.bottom, 14)
            RowRule()
            ScrollView {
                transcript(m)
                    .padding(.horizontal, 20).padding(.vertical, 16)
            }
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image("akar-search").resizable().frame(width: 13, height: 13).foregroundStyle(DesignTokens.Colors.ink3)
                TextField("search", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(DesignTokens.Colors.paperRaised))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).strokeBorder(DesignTokens.Colors.ruleControl, lineWidth: 0.5))
            Text(counted(store.meetings.count, "meeting"))
                .font(.system(size: 11).monospaced()).foregroundStyle(DesignTokens.Colors.ink2)
            Button("import…") { chooseRecordings() }
                .buttonStyle(InkButtonStyle())
                .help("transcribe a recording")
            if !selected.isEmpty {
                Button("delete \(selected.count)") { store.delete(ids: selected); selected = [] }
                    .buttonStyle(InkButtonStyle())
            }
            Button("delete all") { confirmDeleteAll = true }
                .buttonStyle(InkButtonStyle())
                .disabled(store.meetings.isEmpty)
                .confirmationDialog("Delete all \(counted(store.meetings.count, "meeting"))?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                    Button("Delete All", role: .destructive) { store.deleteAll(); selected = [] }
                } message: { Text("This cannot be undone.") }
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 18)
    }

    /// What is live: the recording with its meters and stop, or the
    /// transcription with its progress.
    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 12) {
            if let live = coordinator.recording {
                Text("recording · \(MeetingFolder.durationLabel(.seconds(max(0, now.timeIntervalSince(live.started)))))")
                    .font(.system(size: 12).monospaced()).foregroundStyle(DesignTokens.Colors.ink)
                Meter(level: coordinator.levels.mic)
                if let others = coordinator.levels.others { Meter(level: others) }
                Spacer()
                Button("stop") { coordinator.stopMeeting() }.buttonStyle(InkButtonStyle(primary: true))
            } else if let name = coordinator.importing {
                Text("importing \(name) · english only")
                    .font(.system(size: 12).monospaced()).foregroundStyle(DesignTokens.Colors.ink).lineLimit(1).truncationMode(.middle)
                Spacer()
            } else if let failure = coordinator.importFailure {
                Text(failure).font(.system(size: 12).monospaced()).foregroundStyle(DesignTokens.Colors.ink)
                Spacer()
            } else if let t = coordinator.transcribing {
                Text("transcribing · \(Int(t.fraction * 100))%")
                    .font(.system(size: 12).monospaced()).foregroundStyle(DesignTokens.Colors.ink)
                InkProgress(value: t.fraction).frame(width: 160)
                Spacer()
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 14)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ m: Meeting, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                SelectBox(on: selected.contains(m.id)) { select(m.id) }
                Text(m.started.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                    .font(.system(size: 11).monospaced()).foregroundStyle(DesignTokens.Colors.ink2).frame(width: 44, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    title(m, size: 13)
                    telemetry(m)
                    chips(m)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if renaming != m.id { open = m.id } }
                actions(m)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            if !last { RowRule() }
        }
    }

    @ViewBuilder
    private func title(_ m: Meeting, size: CGFloat) -> some View {
        if renaming == m.id {
            TextField("", text: $renameText)
                .textFieldStyle(.plain).font(.system(size: size))
                .onSubmit { store.rename(id: m.id, title: renameText); renaming = nil }
                .onExitCommand { renaming = nil }
        } else {
            Text(m.title).font(.system(size: size))
        }
    }

    private func actions(_ m: Meeting) -> some View {
        HStack(spacing: 4) {
            if !m.audioFiles.isEmpty, let folder = store.folder(for: m.id) {
                let on = player.playing == m.id
                iconButton(on ? "akar-stop" : "akar-play", on ? "stop" : "play") {
                    player.toggle(id: m.id, urls: m.audioFiles.map { folder.appendingPathComponent($0) })
                }
            }
            iconButton("akar-copy", "copy the transcript") { Output.copyToClipboard(m.transcriptText) }
            if m.isDone, !m.audioFiles.isEmpty, !coordinator.liveIDs.contains(m.id) {
                iconButton("akar-arrow-cycle", "transcribe again") { coordinator.transcribeAgain(m.id) }
            }
            iconButton("akar-pencil", "rename") { renameText = m.title; renaming = m.id }
            if let folder = store.folder(for: m.id) {
                iconButton("akar-arrow-forward-thick", "show in finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            if !coordinator.liveIDs.contains(m.id) {
                iconButton("akar-trash-can", "delete") { store.delete(ids: [m.id]) }
            }
        }
    }

    /// `45m · 2 speakers · slack`.
    private func telemetry(_ m: Meeting) -> some View {
        HStack(spacing: 0) {
            Text(MeetingFolder.durationLabel(m.duration))
            Text(" · ")
            Text(counted(m.speakerCount, "speaker"))
            if m.source == .imported {
                Text(" · imported")
            } else if let app = m.app {
                Text(" · ")
                Text(app.name.lowercased())
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(DesignTokens.Colors.ink2)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Rectangle().fill(DesignTokens.Colors.inkA04))
    }

    @ViewBuilder
    private func chips(_ m: Meeting) -> some View {
        let waitingForModel = m.transcription.state == .pending && !ModelStore.isInstalled
        let folderMissing = !m.published && m.isDone && !store.folderAvailable
        if m.onlyYourSide || m.echo == .affected || m.transcription.state == .failed || waitingForModel || folderMissing {
            HStack(spacing: 6) {
                if m.onlyYourSide { chip("only your side") }
                if m.echo == .affected { chip("on speakers") }
                if m.transcription.state == .failed {
                    chip("transcription failed")
                    Button("retry") { coordinator.retry(m.id) }.buttonStyle(InkButtonStyle())
                }
                if waitingForModel {
                    chip("waiting for the speech model")
                    Button("download") { ModelStore.shared.download() }.buttonStyle(InkButtonStyle())
                }
                if folderMissing {
                    chip("meetings folder unavailable")
                    Button("change") { chooseFolder() }.buttonStyle(InkButtonStyle())
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 10).monospaced()).foregroundStyle(DesignTokens.Colors.ink2)
            .padding(.horizontal, 5).padding(.vertical, 1).background(Rectangle().fill(DesignTokens.Colors.inkA08))
    }

    /// The paragraphs, each headed by its speaker and time.
    private func transcript(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if m.paragraphs.isEmpty {
                Text(m.transcription.state == .done ? "nothing was said" : "not transcribed yet")
                    .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink3)
            }
            ForEach(Array(m.paragraphs.enumerated()), id: \.offset) { _, p in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(m.speakerName(p.speaker)).bold()) · \(TranscriptRender.timestamp(ms: p.startMs))")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(DesignTokens.Colors.ink3)
                    Text(p.text).font(.system(size: 12)).foregroundStyle(DesignTokens.Colors.ink2).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Rectangle().fill(DesignTokens.Colors.inkA04))
    }

    private func select(_ id: UUID) {
        selected = HistorySelection.clicked(id, extending: NSEvent.modifierFlags.contains(.shift),
                                            anchor: anchor, in: filtered.map(\.id), selected: selected)
        anchor = id
    }

    private func iconButton(_ image: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(image).resizable().frame(width: 14, height: 14)
        }
        .buttonStyle(QuietButtonStyle(side: 24))
        .help(help)
    }

    // MARK: Footer

    private var folderSubtitle: String {
        guard store.folderAvailable else { return "unavailable" }
        let root = store.publishedRoot
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = root.path
        if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        return MeetingFolder.isInICloudDrive(root) ? path + " · icloud drive" : path
    }

    private var systemAudioStatus: String {
        switch coordinator.systemAudioTest {
        case .notTested: "not tested"
        case .testing: "testing…"
        case .working: "working"
        case .silent: "silent"
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            SettingsRow(label: "keep") {
                Picker("", selection: Binding(get: { settings.meetingLimit }, set: { settings.meetingLimit = $0; store.prune() })) {
                    ForEach([50, 100, 250, 500], id: \.self) { Text("the last \(counted($0, "meeting"))").tag($0) }
                    Text("everything · never delete").tag(0)
                }.labelsHidden().fixedSize()
            }
            SettingsRow(label: "keep the audio", subtitle: "deleted along with the meeting") {
                Toggle("", isOn: $settings.meetingKeepAudio).toggleStyle(.switch).labelsHidden()
            }
            SettingsRow(label: "meetings folder", subtitleView: AnyView(Text(folderSubtitle))) {
                HStack(spacing: 8) {
                    Button("show") { NSWorkspace.shared.activateFileViewerSelecting([store.publishedRoot]) }.buttonStyle(InkButtonStyle())
                        .disabled(!store.folderAvailable)
                    Button("change") { chooseFolder() }.buttonStyle(InkButtonStyle())
                }
            }
            SettingsRow(label: "system audio", last: true, subtitleView: AnyView(systemAudioLines)) {
                HStack(spacing: 8) {
                    Text(systemAudioStatus).font(.system(size: 11).monospaced()).foregroundStyle(DesignTokens.Colors.ink2)
                    if coordinator.systemAudioTest == .silent {
                        Button("system settings") { NSWorkspace.shared.open(SecureInput.systemAudioSettingsURL) }.buttonStyle(InkButtonStyle())
                    }
                    Button("test") { coordinator.testSystemAudio() }.buttonStyle(InkButtonStyle())
                        .disabled(coordinator.systemAudioTest == .testing || coordinator.recording != nil)
                }
            }
            if let usage = store.diskUsage {
                RowRule()
                Text("meetings use \(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file).lowercased())")
                    .font(.system(size: 11).monospaced()).foregroundStyle(DesignTokens.Colors.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
    }

    @ViewBuilder private var systemAudioLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            if coordinator.systemAudioTest == .silent { Text("quit and reopen after granting") }
            Text("the other people on a call are not told you are recording.")
        }
    }

    private func chooseRecordings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        coordinator.importRecordings(panel.urls)
    }

    /// An open panel for directories; nothing is moved.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.publishedRoot
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.meetingsFolder = url == MeetingFolder.defaultPublishedRoot ? nil : url
        store.reload()
        store.republishPending()
    }
}

/// A level meter: a hairline bar filled with ink to the level.
private struct Meter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(DesignTokens.Colors.inkA08)
                Rectangle().fill(DesignTokens.Colors.ink).frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .frame(width: 80, height: 6)
        .animation(.linear(duration: 0.1), value: level)
    }
}
