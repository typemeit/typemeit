import AppKit
import SwiftUI

/// How wide the page's reading text runs: the summary, the transcript, answers and hook output.

/// One meeting on its own page: its title and when, the summary, the whole
/// transcript with room to read it, who spoke and for how long, where it was
/// and how it was processed, and the player, whose scrubber is everyone's
/// turns laid along the meeting.
struct MeetingPage: View {
    let meeting: Meeting
    let back: () -> Void
    @State private var store = MeetingStore.shared
    @State private var coordinator = MeetingCoordinator.shared
    @State private var player = RecordingPlayer.shared
    @State private var deleting = false
    @State private var renaming = false
    @State private var pausing = false
    @State private var title = ""
    @State private var titleFocused = true
    /// The speaker whose name field is open in the rail, and what is typed in it.
    @State private var naming: String?
    @State private var name = ""
    @State private var nameFocused = true
    /// The highlighted name in the field's list.
    @State private var pick = 0
    /// The rail's hook tray is open, and its ticks; nil until one changes.
    /// The hook whose result tab is showing; nil for the newest.
    @State private var hookTab: String?
    /// The open speaker's clips, and which one is showing.
    @State private var clips: [SpeakerAssign.Clip] = []
    @State private var clip = 0
    /// People named in the other meetings, read when a field first opens.
    @State private var past: [SpeakerAssign.Person] = []
    /// Names the voice model suggests for unknown speakers, by speaker id (8.7).
    @State private var suggested: [String: String] = [:]
    @State private var settings = Settings.shared
    /// The `.tmi` file the share menu is showing.
    @State private var sharing: URL?
    /// What the find field looks for in the transcript.
    @State private var find: String
    /// Which of the find's hits is current.
    @State private var hit = 0

    /// Opens on the first unknown speaker's field: the list's "unknown speakers" button.
    let nameFirst: Bool

    /// `find` starts as the list's search, so the page opens on what matched.
    init(meeting: Meeting, find: String = "", nameFirst: Bool = false, back: @escaping () -> Void) {
        self.meeting = meeting
        self.back = back
        self.nameFirst = nameFirst
        _find = State(initialValue: find)
    }

    private static let railWidth: CGFloat = 344
    /// How tall a hook's result grows before it scrolls inside its tab.
    private static let hookOutputHeight: CGFloat = 420

    private var recording: Bool { coordinator.recording?.id == meeting.id }
    private var live: Bool { coordinator.liveIDs.contains(meeting.id) }

    /// The meeting's tracks, when its audio was kept.
    private var audioURLs: [URL]? {
        guard !meeting.audioFiles.isEmpty, let folder = store.folder(for: meeting.id) else { return nil }
        return meeting.audioFiles.map { folder.appendingPathComponent($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView { article }
                        .onChange(of: find, initial: true) { _, _ in
                            hit = 0
                            reveal(proxy)
                        }
                        .onChange(of: hit) { _, _ in reveal(proxy) }
                }
                .frame(maxWidth: .infinity)
                ScrollView { rail }
                    .frame(width: MeetingPage.railWidth)
                    .overlay(alignment: .leading) { Rectangle().fill(DesignTokens.Colors.rule).frame(width: DesignTokens.hairline) }
            }
            .frame(maxHeight: .infinity)
            PageAudioFoot(id: meeting.id, urls: audioURLs, durationMs: meeting.durationMs)
        }
        .onAppear {
            coordinator.summarise(meeting.id)
            if nameFirst { openNaming(SpeakerAssign.nextUnknown(after: nil, in: meeting)) }
        }
        .task(id: [store.revision, settings.meetingLearnVoices ? 1 : 0]) {
            suggested = settings.meetingLearnVoices ? await VoiceLibrary.shared.suggestions(for: meeting, among: store.meetings) : [:]
        }
    }

    // MARK: Top

    private var topBar: some View {
        // Esc in a field gives up the edit, not the page.
        PageTopBar(list: "meetings", backShortcut: renaming || naming != nil ? nil : .cancelAction, back: back) {
            if !hits.isEmpty || !query.isEmpty {
                Text(hits.isEmpty ? "none" : "\(hit + 1)/\(hits.count)")
                    .font(Square.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.ink3)
            }
            SquareField(placeholder: "find", text: $find, icon: "akar-search", findKey: !renaming && naming == nil,
                        onSubmit: step, onCancel: { if find.isEmpty { back() } else { find = "" } })
                .frame(width: 200)
                .padding(.trailing, 4)
            PageCopyButton(help: "copy the transcript") { Output.copyToClipboard(meeting.transcriptText) }
                .disabled(meeting.paragraphs.isEmpty)
            if meeting.isDone, !meeting.paragraphs.isEmpty, !live {
                // The share menu under the button; the button can also be
                // dragged, which drops the `.tmi` file into a message or a
                // folder (docs/meetings.md 7.16).
                Button {
                    if let file = store.shareFile(meeting.id) { sharing = file }
                } label: {
                    SquareIcon("akar-share-box", size: 14)
                }
                .buttonStyle(SquareIconButtonStyle())
                .help("share")
                .accessibilityLabel("share")
                .background(SharePicker(file: sharing) { sharing = nil })
                .onDrag { store.shareFile(meeting.id).flatMap(NSItemProvider.init(contentsOf:)) ?? NSItemProvider() }
            }
            // Edits the title and every speaker's name, those the meeting gave too.
            Button {
                if renaming {
                    store.rename(id: meeting.id, title: title)
                    renaming = false
                    openNaming(nil)
                } else {
                    title = meeting.title
                    titleFocused = true
                    renaming = true
                }
            } label: {
                SquareIcon(renaming ? "akar-check" : "akar-pencil", size: renaming ? 12 : 14)
            }
            .buttonStyle(SquareIconButtonStyle())
            .help(renaming ? "done" : "edit")
            .accessibilityLabel(renaming ? "done" : "edit")
            if !live {
                Button { deleting.toggle() } label: { SquareIcon("akar-trash-can", size: 14) }
                    .buttonStyle(SquareIconButtonStyle())
                    .help("delete")
                    .accessibilityLabel("delete")
                    .squarePopover(isPresented: $deleting) { deleteConfirm }
            }
        }
    }

    private var query: String { find.trimmingCharacters(in: .whitespaces) }

    private var hits: [TranscriptFind.Hit] { TranscriptFind.hits(of: query, in: meeting.paragraphs.map(\.text)) }

    /// Return moves to the next hit, shift-return to the one before.
    private func step() {
        let count = hits.count
        guard count > 0 else { return }
        let by = NSEvent.modifierFlags.contains(.shift) ? count - 1 : 1
        hit = (hit + by) % count
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        let all = hits
        guard all.indices.contains(hit) else { return }
        // A hit in an aside scrolls to the turn it is shown in.
        let turn = TranscriptRender.rows(meeting.paragraphs).first { $0.contains(all[hit].paragraph) }?[0] ?? all[hit].paragraph
        withAnimation(.easeOut(duration: DesignTokens.Duration.n2)) { proxy.scrollTo(turn, anchor: .center) }
    }

    /// While the audio is kept, it can go on its own and the transcript stay.
    private var deleteConfirm: some View {
        SquareAudioDeleteConfirm(title: "delete this meeting?",
                                 audio: audioURLs.map { _ in MeetingsTab.length(meeting.durationMs) },
                                 cancel: { deleting = false },
                                 deleteAudio: {
                                     if player.playing == meeting.id { player.stop() }
                                     store.deleteAudio(meeting.id)
                                     deleting = false
                                 },
                                 deleteEverything: {
                                     if player.playing == meeting.id { player.stop() }
                                     deleting = false
                                     store.delete(ids: [meeting.id])
                                     back()
                                 })
    }

    // MARK: Article

    private var article: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleView
            Text(dateLine)
                .font(Square.mono(12))
                .foregroundStyle(DesignTokens.Colors.ink2)
                .padding(.top, 10)
            folderSuggestion
            state.padding(.top, 20)
            asking
            hooks
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline) {
                    SquareSubhead(text: "transcript", first: true)
                    Spacer()
                    if recording {
                        Button(coordinator.transcribingSoFar ? "transcribing…" : "transcribe now") {
                            Task { await coordinator.transcribeSoFar() }
                        }
                        .buttonStyle(SquareButtonStyle(kind: .quiet))
                        .disabled(coordinator.transcribingSoFar)
                    }
                }
                MeetingTranscript(meeting: meeting, audio: audioURLs, find: query,
                                  current: hits.indices.contains(hit) ? hits[hit] : nil,
                                  naming: naming)
            }
            .padding(.top, 26)
        }
        .padding(.top, 26)
        .padding(.leading, 44)
        .padding(.trailing, 40)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Claude answering a question asked in this meeting, live.
    @ViewBuilder private var asking: some View {
        if let asked = coordinator.askingIn, asked.meeting == meeting.id, let runID = asked.question.runID {
            Group {
                // Transcribing or finding the question, which the prompt line names until Claude Code starts.
                if coordinator.askPreparing {
                    SquareClaudeThread(lines: [.prompt(asked.question.text)], status: .running, footer: "", stop: { coordinator.cancelAsk() })
                } else {
                    ClaudeRunOutput(id: runID)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 26)
        }
    }

    /// Each hook's latest result, or its run now, as a tab, the newest picked
    /// until one is clicked; when it ran and run again at the tab line's end.
    /// A long result scrolls inside the panel.
    @ViewBuilder private var hooks: some View {
        let lines = hookLines.filter { if case .notRun = $0.status { false } else { true } }
        if !lines.isEmpty {
            let picked = lines.firstIndex { $0.name == hookTab } ?? lines.count - 1
            SquareTabs(tabs: lines.map { line in
                           let state: SquareTab.State = switch line.status {
                           case .ran(let run): run.failed ? .failed : .idle
                           case .running: .running
                           case .notRun: .idle
                           }
                           return SquareTab(name: line.name, state: state)
                       },
                       picked: Binding(get: { picked }, set: { hookTab = lines[$0].name })) {
                hookTabEnd(lines[picked])
            } content: { index in
                ViewThatFits(in: .vertical) {
                    hookOutput(lines[index]).padding(14)
                    ScrollView { hookOutput(lines[index]).padding(14) }
                }
                .frame(maxHeight: MeetingPage.hookOutputHeight)
            }
            .padding(.top, 26)
        }
    }

    @ViewBuilder private func hookTabEnd(_ line: HookLine) -> some View {
        if line.run != nil {
            HStack(spacing: 10) {
                if let hookID = line.hookID {
                    Button { coordinator.runHooks(meeting.id, only: [hookID]) } label: { SquareIcon("akar-arrow-cycle", size: 12) }
                        .buttonStyle(SquareIconButtonStyle())
                        .disabled(hooksRunning)
                        .help("run again")
                        .accessibilityLabel("run \(line.name) again")
                }
            }
        }
    }

    private func hookOutput(_ line: HookLine) -> some View {
        ClaudeRunOutput(id: line.id, kept: line.run.map {
            .init(prompt: $0.prompt, answer: $0.output, failed: $0.failed, sessionID: $0.sessionID, calls: $0.calls, ranAt: $0.ranAt)
        })
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A hook's latest run on the meeting, its run going on now, or a hook
    /// that has not run on it.
    fileprivate struct HookLine: Identifiable {
        enum Status {
            case ran(Meeting.HookRun)
            case running
            case notRun
        }

        /// The run's id, which its live output and its kept output share;
        /// the hook's own for one not run.
        let id: UUID
        let name: String
        /// The hook it ran, while it is still in settings.
        let hookID: UUID?
        let status: Status

        var run: Meeting.HookRun? {
            if case .ran(let run) = status { run } else { nil }
        }
    }

    /// The finished ones by when they ran, then those running, then the
    /// hooks that could run and have not. Runs started together share a
    /// second, so ties go in the hooks page's order.
    private var hookLines: [HookLine] {
        let running = coordinator.runningHooks[meeting.id] ?? []
        var latest: [String: Meeting.HookRun] = [:]
        for run in meeting.hookRuns ?? [] { latest[run.name] = run }
        let finished = latest.values
            .filter { run in !running.contains { $0.name == run.name } }
            .sorted { ($0.ranAt, hookPlace($0.name), $0.name) < ($1.ranAt, hookPlace($1.name), $1.name) }
        let lines = finished.map { run in HookLine(id: run.id, name: run.name, hookID: settings.meetingHooks.first { $0.name == run.name }?.id, status: .ran(run)) }
            + running.map { HookLine(id: $0.runID, name: $0.name, hookID: $0.hookID, status: .running) }
        guard ClaudeRun.isAvailable else { return lines }
        return lines + coordinator.runnableHooks
            .filter { hook in !lines.contains { $0.name == hook.name } }
            .map { HookLine(id: $0.id, name: $0.name, hookID: $0.id, status: .notRun) }
    }

    /// Where a hook sits on the hooks page; one since deleted goes last.
    private func hookPlace(_ name: String) -> Int {
        settings.meetingHooks.firstIndex { $0.name == name } ?? settings.meetingHooks.count
    }

    private var hooksRunning: Bool { coordinator.runningHooks[meeting.id] != nil }

    /// The rail's hooks: on a finished meeting while Claude Code can run
    /// them or there are results.
    private var showsHooks: Bool {
        meeting.isDone && !meeting.paragraphs.isEmpty && !live && (ClaudeRun.isAvailable || !hookLines.isEmpty)
    }

    /// "hooks" with ▷ for the ones switched on, then each hook's line with
    /// ▷ for that one in the hooks page's order, then the way to a new one.
    @ViewBuilder private var railHooks: some View {
        let runnable = Set(coordinator.runnableHooks.map(\.id))
        let on = coordinator.runnableHooks.filter(\.on).count
        HStack(alignment: .lastTextBaseline) {
            SquareSubhead(text: "hooks")
            Spacer()
            if coordinator.hooksReady {
                Button { coordinator.runHooks(meeting.id) } label: { SquareRunLabel(count: on, size: 11) }
                    .buttonStyle(SquareButtonStyle(small: true))
                    .disabled(on == 0 || hooksRunning)
                    .help("run \(counted(on, "hook"))")
                    .accessibilityLabel("run \(counted(on, "hook"))")
            }
        }
        let lines = hookLines.enumerated()
            .sorted { (hookPlace($0.element.name), $0.offset) < (hookPlace($1.element.name), $1.offset) }
            .map(\.element)
        if !lines.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    let hook = line.hookID.flatMap { runnable.contains($0) ? $0 : nil }
                    HookRailLine(number: index + 1, line: line,
                                 run: hook.map { hook in { coordinator.runHooks(meeting.id, only: [hook]) } },
                                 enabled: !hooksRunning)
                }
            }
            .padding(.top, 8)
        }
        if ClaudeRun.isAvailable {
            SquareLink(title: "new hook", color: DesignTokens.Colors.ink2) {
                AppState.shared.startNewHook = true
                AppState.shared.settingsTab = .hooks
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        }
    }

    /// The title, or while renaming a field over an ink rule: return keeps
    /// it, esc gives up.
    @ViewBuilder private var titleView: some View {
        if renaming {
            SquareTextInput(placeholder: "title", text: $title, font: Square.appKitMono(30), focused: $titleFocused,
                            onSubmit: {
                                store.rename(id: meeting.id, title: title)
                                renaming = false
                            },
                            onCancel: { renaming = false })
                .frame(maxWidth: .infinity)
                .padding(.bottom, 2)
                .overlay(alignment: .bottom) { SquareRule(color: DesignTokens.Colors.ink) }
        } else {
            Text(meeting.title)
                .font(Square.mono(30))
                .tracking(-0.6)
                .foregroundStyle(DesignTokens.Colors.ink)
                .textSelection(.enabled)
        }
    }

    /// For a meeting in no folder: the model's folder suggestion to take or
    /// leave, "new folder" when no meeting is in it yet, or the link that
    /// asks for one when it has a summary.
    @ViewBuilder private var folderSuggestion: some View {
        if let suggestion = meeting.openFolderSuggestion {
            HStack(spacing: 8) {
                Text(store.folderCounts.contains { $0.name == suggestion } ? "folder: \(suggestion)?" : "new folder: \(suggestion)?")
                    .font(Square.mono(12))
                    .foregroundStyle(DesignTokens.Colors.ink)
                Button("yes") { store.file(ids: [meeting.id], in: suggestion) }
                    .buttonStyle(SquareButtonStyle(small: true))
                Button("no") { store.file(ids: [meeting.id], in: nil) }
                    .buttonStyle(SquareButtonStyle(kind: .quiet, small: true))
            }
            .padding(.top, 10)
        } else if meeting.folder == nil {
            if coordinator.suggestingFolder.contains(meeting.id) {
                Text("suggesting a folder…")
                    .font(Square.mono(12))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .padding(.top, 10)
            } else if meeting.isDone, !live, !(meeting.summary ?? "").isEmpty {
                SquareLink(title: "suggest a folder", size: 12, color: DesignTokens.Colors.ink2) { coordinator.suggestFolder(meeting.id) }
                    .padding(.top, 10)
            }
        }
    }

    /// "thursday 24 september · 10:21–10:32".
    private var dateLine: String {
        let day = meeting.started.formatted(.dateTime.weekday(.wide).day().month(.wide)).lowercased()
        let time = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        if recording { return "\(day) · \(meeting.started.formatted(time))– · live" }
        let end = meeting.ended ?? meeting.started.addingTimeInterval(Double(meeting.durationMs) / 1000)
        return "\(day) · \(meeting.started.formatted(time))–\(end.formatted(time))"
    }

    /// How far its transcription has got, what it still needs, or its summary.
    @ViewBuilder private var state: some View {
        switch MeetingState.phase(meeting, coordinator: coordinator, store: store, diarizer: DiarizerModelStore.shared) {
        case .transcribing(let run):
            HStack(spacing: 12) {
                Text(pausing ? "pausing…" : run.progress.label)
                    .font(Square.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.ink2)
                // A pause takes effect between chunks, so only while there are chunks left.
                if case .transcribing = run.progress {
                    SquareBar(fraction: run.fraction, width: 220)
                    if !pausing {
                        Button("pause") {
                            pausing = true
                            coordinator.stopTranscribing(meeting.id)
                        }
                        .buttonStyle(SquareButtonStyle(small: true))
                        .help("stops after this chunk. carry on starts from the next")
                    }
                }
            }
            .onChange(of: coordinator.transcribing?.id) { _, running in if running != meeting.id { pausing = false } }
        case .queued:
            Text(MeetingPhase.queuedLabel).font(Square.sans(14)).foregroundStyle(DesignTokens.Colors.ink3)
        case .summarising:
            Text(MeetingPhase.summarisingLabel).font(Square.sans(14)).foregroundStyle(DesignTokens.Colors.ink3)
        case .needs:
            MeetingChips(meeting: meeting)
        // The rail names unknown speakers here, so the summary shows over them.
        case .unknownSpeakers, .summary:
            if let summary = meeting.summary, !summary.isEmpty {
                Text(summary)
                    .font(Square.sans(15))
                    .lineSpacing(6)
                    .foregroundStyle(DesignTokens.Colors.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .none:
            EmptyView()
        }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !meeting.speakers.isEmpty {
                SquareSubhead(text: "people", first: true)
                VStack(spacing: 8) {
                    ForEach(meeting.speakers) { speaker in person(speaker) }
                }
                .onChange(of: name) { old, new in typed(old, new) }
            }
            SquareSubhead(text: "where", first: meeting.speakers.isEmpty)
            Text(whereLine)
                .font(Square.mono(12))
                .foregroundStyle(DesignTokens.Colors.ink)
            if let callLine {
                SquareSubhead(text: "call")
                Text(callLine)
                    .font(Square.mono(12))
                    .foregroundStyle(DesignTokens.Colors.ink)
            }
            if let folder = store.folder(for: meeting.id) {
                SquareSubhead(text: "folder")
                Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: {
                    Text(MeetingPage.shortPath(folder))
                        .font(Square.mono(11))
                        .lineSpacing(3)
                        .foregroundStyle(DesignTokens.Colors.ink2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("show in finder")
            }
            SquareSubhead(text: "processing")
            RailFacts(facts: processing)
            if showsHooks { railHooks }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 22)
        .frame(width: MeetingPage.railWidth, alignment: .topLeading)
    }

    private static let nameHeight: CGFloat = 20

    /// A speaker, how much of the talking they did, and its name. An unknown
    /// speaker's name, or any name while the page is edited, is a field; a
    /// click opens it, plays the speaker, and lists names to give it.
    private func person(_ speaker: Meeting.Speaker) -> some View {
        let total = max(1, meeting.speakers.reduce(0) { $0 + $1.talkMs })
        let share = Double(speaker.talkMs) / Double(total)
        let unknown = SpeakerAssign.isUnknown(speaker)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Group {
                    if naming == speaker.id {
                        SquareTextInput(placeholder: speaker.name, text: $name, font: Square.appKitMono(12), focused: $nameFocused,
                                        onSubmit: submitName, onCancel: { openNaming(nil) }, onCommand: nameCommand)
                            .padding(.horizontal, 5)
                            .frame(height: MeetingPage.nameHeight)
                            .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
                    } else {
                        Button { openNaming(speaker.id) } label: {
                            Text(speaker.name)
                                .font(Square.mono(12))
                                .foregroundStyle(unknown ? DesignTokens.Colors.ink3 : DesignTokens.Colors.ink)
                                .lineLimit(1)
                                .padding(.horizontal, unknown || renaming ? 5 : 0)
                                .frame(maxWidth: .infinity, minHeight: MeetingPage.nameHeight, alignment: .leading)
                                .overlay {
                                    if unknown || renaming { Rectangle().strokeBorder(DesignTokens.Colors.ruleControl, lineWidth: DesignTokens.hairline) }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(unknown ? "name" : "rename")
                    }
                }
                .frame(width: 144, alignment: .leading)
                Rectangle()
                    .fill(DesignTokens.Colors.inkA08)
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle().fill(DesignTokens.Colors.ink).frame(width: geo.size.width * share)
                        }
                    }
                Text("\(Int((share * 100).rounded()))%")
                    .font(Square.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .frame(width: 34, alignment: .trailing)
            }
            if naming == speaker.id {
                SpeakerNames(meetingID: meeting.id, clips: clips, clip: clip, options: nameOptions, pick: pick,
                             play: { clip = $0; playClip() }, choose: choose)
            } else if unknown, let suggestion = suggested[speaker.id] {
                Button { _ = store.assign(.name(suggestion), to: speaker.id, in: meeting.id) } label: {
                    Text("\(suggestion)?")
                        .font(Square.mono(11))
                        .foregroundStyle(DesignTokens.Colors.ink3)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("matched by voice. click to accept")
            }
        }
    }

    // MARK: Naming speakers

    private var nameOptions: [SpeakerAssign.Option] {
        guard let naming else { return [] }
        return SpeakerAssign.options(for: naming, in: meeting, query: name, past: past, voice: suggested[naming])
    }

    /// Opens `id`'s field and plays its first clip; nil closes the field.
    /// `in` is the meeting as just saved, before the page has it.
    private func openNaming(_ id: String?, in saved: Meeting? = nil) {
        let m = saved ?? meeting
        if id == nil, naming != nil, player.playing == meeting.id, !player.paused { player.pause() }
        naming = id
        name = ""
        pick = 0
        clip = 0
        clips = id.map { SpeakerAssign.clips(for: $0, in: m) } ?? []
        guard id != nil else { return }
        if past.isEmpty { past = SpeakerAssign.past(store.meetings, for: m) }
        nameFocused = true
        playClip()
    }

    private func playClip() {
        guard clips.indices.contains(clip), let urls = audioURLs else { return }
        let c = clips[clip]
        player.play(id: meeting.id, urls: urls, from: Double(c.startMs) / 1000, until: Double(c.endMs) / 1000)
    }

    /// Gives the open speaker the name; from an unknown speaker it moves on
    /// to the next one.
    private func choose(_ option: SpeakerAssign.Option) {
        guard let id = naming else { return }
        let wasUnknown = meeting.speakers.first { $0.id == id }.map(SpeakerAssign.isUnknown) ?? false
        guard let saved = store.assign(option.choice, to: id, in: meeting.id) else { return }
        openNaming(wasUnknown ? SpeakerAssign.nextUnknown(after: id, in: saved) : nil, in: saved)
    }

    private func submitName() {
        let options = nameOptions
        if options.indices.contains(pick) { choose(options[pick]) }
    }

    /// ↑↓ move through the names, tab and shift-tab to the next unknown speaker.
    private func nameCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            pick = min(pick + 1, max(nameOptions.count - 1, 0))
        case #selector(NSResponder.moveUp(_:)):
            pick = max(pick - 1, 0)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            let back = selector == #selector(NSResponder.insertBacktab(_:))
            if let next = SpeakerAssign.nextUnknown(after: naming, in: meeting, backwards: back) { openNaming(next) }
        default:
            return false
        }
        return true
    }

    /// In an empty field a number key picks that name and space plays the clip again.
    private func typed(_ old: String, _ new: String) {
        pick = 0
        guard old.isEmpty, let naming else { return }
        if new == " " {
            name = ""
            playClip()
        } else if let key = Int(new), let option = SpeakerAssign.options(for: naming, in: meeting, query: "", past: past).first(where: { $0.key == key }) {
            name = ""
            choose(option)
        }
    }

    /// The app and its channel or call, the room, and who sent a shared one.
    private var whereLine: String {
        var parts: [String]
        if meeting.kind == .room {
            parts = ["the room"]
        } else {
            parts = [meeting.app?.name.lowercased() ?? "a call"]
        }
        if let from = meeting.sharedBy, !from.isEmpty { parts.append("from \(from.lowercased())") }
        return parts.joined(separator: " · ")
    }

    /// Which call it was: the name it showed, then the Meet code or the
    /// huddle's channel and workspace. Nil when the window said neither.
    private var callLine: String? {
        let parts = [meeting.names?.name, meeting.names?.channel ?? meeting.names?.call, meeting.names?.workspace].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What ran on the meeting and what it came to, from what the meeting
    /// records about itself.
    private var processing: [RailFact] {
        let t = meeting.transcription
        let running = coordinator.transcribing?.id == meeting.id
        var rows: [RailFact] = []
        if running, let run = coordinator.transcribing {
            rows.append(RailFact(key: "asr", value: "\(t.asr ?? ModelStore.version) · \(Int(run.fraction * 100))%"))
        } else {
            rows.append(RailFact(key: "asr", value: t.asr.map { MeetingPage.timed($0, t.asrMs) } ?? "none yet", waiting: t.asr == nil))
        }
        let stage = running ? coordinator.transcribing?.progress : nil
        rows.append(RailFact(key: "speakers", value: t.diarizer.map { MeetingPage.timed(DiarizerModelStore.label(of: $0), t.speakersMs) }
            ?? (stage == .findingSpeakers ? "finding" : meeting.isDone ? "none" : "waiting"), waiting: t.diarizer == nil))
        rows.append(RailFact(key: "names from", value: MeetingPage.nameSource(meeting) ?? (meeting.isDone ? "none" : "waiting"),
                             waiting: MeetingPage.nameSource(meeting) == nil))
        if meeting.kind == .call { rows.append(RailFact(key: "echo", value: MeetingPage.echo(meeting.echo), waiting: meeting.echo == .notMeasured)) }
        if let took = t.tookMs, meeting.durationMs > 0 {
            rows.append(RailFact(key: "transcribed", value: "\(lengthInSeconds(ms: took)) · \(timesFaster(audioMs: meeting.durationMs, tookMs: took))"))
        }
        let writing = coordinator.summarising.contains(meeting.id) || stage == .summarising
        let summary = meeting.summary.map { _ in MeetingPage.timed("apple intelligence", t.summaryMs) } ?? (writing ? "writing" : meeting.isDone ? "none" : "waiting")
        rows.append(RailFact(key: "summary", value: summary, waiting: meeting.summary == nil))
        rows.append(RailFact(key: "title", value: MeetingPage.titleSource(meeting.titleSource)))
        return rows
    }

    private static func nameSource(_ meeting: Meeting) -> String? {
        let sources = Set(meeting.speakers.compactMap(\.nameSource))
        if sources.contains(.captions) { return "captions" }
        if sources.contains(.speaking) { return "speaking indicator" }
        if sources.contains(.roster) { return "who was there" }
        if sources.contains(.user) { return "you" }
        return nil
    }

    private static func echo(_ echo: Meeting.Echo) -> String {
        switch echo {
        case .notMeasured: "not measured"
        case .clean: "clean"
        case .affected: "affected"
        }
    }

    private static func titleSource(_ source: Meeting.TitleSource) -> String {
        switch source {
        case .app: "from the app"
        case .user: "named by you"
        case .generated: "apple intelligence"
        case .roster: "from who was there"
        }
    }

    /// What ran, and how long it took when the meeting recorded that.
    private static func timed(_ what: String, _ ms: Int?) -> String {
        ms.map { "\(what) · \(lengthInSeconds(ms: $0))" } ?? what
    }

    /// "~/…/Meetings/2026-09-24 11m pricing page review": home as ~, and
    /// only the last two folders spelled out.
    static func shortPath(_ folder: URL) -> String {
        let parts = folder.pathComponents
        guard parts.count > 2 else { return folder.path }
        return "~/…/" + parts.suffix(2).joined(separator: "/")
    }
}

/// The transcript: each turn's speaker and time, and what they said, with
/// each question offered to Claude after the turn it was heard in. The
/// line playing is in full ink; a time, clicked, plays from there; what the
/// find matches is marked, the current hit on the slab. Lazy: an hour's
/// meeting is hundreds of turns, and only those on screen are built.
private struct MeetingTranscript: View {
    let meeting: Meeting
    let audio: [URL]?
    let find: String
    let current: TranscriptFind.Hit?
    /// The speaker whose name is open in the rail.
    var naming: String? = nil
    @State private var player = RecordingPlayer.shared

    var body: some View {
        let loaded = player.playing == meeting.id
        // Ticks only while playing, for which line is in ink.
        TimelineView(.animation(minimumInterval: 0.5, paused: !loaded || player.paused)) { _ in
            let current = loaded ? meeting.paragraphs.lastIndex { $0.startMs <= Int(player.currentTime * 1000) } : nil
            let rows = Dictionary(uniqueKeysWithValues: TranscriptRender.rows(meeting.paragraphs).map { ($0[0], $0) })
            LazyVStack(alignment: .leading, spacing: 0) {
                if meeting.paragraphs.isEmpty {
                    Text(meeting.transcription.state == .done ? "nothing was said" : "not transcribed yet")
                        .font(Square.sans(14))
                        .foregroundStyle(DesignTokens.Colors.ink3)
                }
                ForEach(TranscriptRender.entries(meeting), id: \.self) { entry in
                    switch entry {
                    case .paragraph(let i): turn(rows[i] ?? [i], current: current)
                    case .question(let i): question(meeting.questions?[i])
                    }
                }
            }
        }
    }

    /// The speaker and time column, and the gap before what was said.
    private static let speakerWidth: CGFloat = 88
    private static let speakerGap: CGFloat = 20
    /// The space inside the box around Claude's reply.
    private static let replyPadding: CGFloat = 14

    /// One turn: its first paragraph's speaker and time, and the text of
    /// every paragraph in `row`, each aside in brackets under its speaker.
    private func turn(_ row: [Int], current: Int?) -> some View {
        let paragraph = meeting.paragraphs[row[0]]
        var text = AttributedString()
        for i in row {
            if i != row[0] { text += AttributedString(" ") }
            if TranscriptRender.bracketed(i, in: row, of: meeting.paragraphs) {
                var aside = AttributedString("[\(SpeakerAssign.firstName(of: meeting.paragraphs[i].speaker, in: meeting)): ")
                aside += marked(meeting.paragraphs[i].text, paragraph: i)
                aside += AttributedString("]")
                // The current find hit keeps its own colour.
                for run in aside.runs where run.foregroundColor == nil { aside[run.range].foregroundColor = DesignTokens.Colors.ink3 }
                text += aside
            } else {
                text += marked(meeting.paragraphs[i].text, paragraph: i)
            }
        }
        return HStack(alignment: .firstTextBaseline, spacing: Self.speakerGap) {
            VStack(alignment: .leading, spacing: 2) {
                speaker(paragraph.speaker)
                time(paragraph)
            }
            .frame(width: Self.speakerWidth, alignment: .leading)
            Text(text)
                .font(Square.sans(14))
                .lineSpacing(5)
                .foregroundStyle(current.map(row.contains) == true ? DesignTokens.Colors.ink : DesignTokens.Colors.ink2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .id(row[0])
    }

    /// A question offered to Claude, under the turn it was heard in: the
    /// answer, or what the user did instead of asking.
    @ViewBuilder private func question(_ question: Meeting.Question?) -> some View {
        if let question {
            VStack(alignment: .leading, spacing: 8) {
                // As the dictation page heads its question.
                HStack(spacing: 8) {
                    SquareClaudeMark(size: 13)
                    Text("claude").font(Square.mono(12, weight: .medium))
                }
                .foregroundStyle(DesignTokens.Colors.ink2)
                if question.result != .asked || question.answer == nil && question.runID == nil {
                    Text(question.text)
                        .font(Square.mono(13))
                        .foregroundStyle(question.result == .asked ? DesignTokens.Colors.ink : DesignTokens.Colors.ink3)
                }
                if question.result == .asked, let answer = question.answer {
                    ClaudeRunOutput(id: question.runID ?? UUID(), kept: .init(prompt: question.text, answer: answer, failed: false, sessionID: question.sessionID, calls: question.calls))
                } else if let runID = question.runID, ClaudeLive.shared.running.contains(runID) {
                    ClaudeRunOutput(id: runID)
                } else {
                    Text(TranscriptRender.outcome(question.result))
                        .font(Square.mono(12))
                        .foregroundStyle(DesignTokens.Colors.ink3)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A reply to the turn: a box whose edge lines up with the turn's text.
            .padding(Self.replyPadding)
            .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
            .padding(.leading, Self.speakerWidth + Self.speakerGap)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
    }

    /// The speaker's name: shaded while unknown, on the slab while its
    /// field is open.
    private func speaker(_ id: String) -> some View {
        let open = naming == id
        let unknown = meeting.speakers.first { $0.id == id }.map(SpeakerAssign.isUnknown) ?? false
        return Text(SpeakerAssign.firstName(of: id, in: meeting))
            .font(Square.mono(12, weight: .medium))
            .foregroundStyle(open ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .background(open ? DesignTokens.Colors.slab : unknown ? DesignTokens.Colors.inkA08 : .clear)
            .padding(.horizontal, -4)
    }

    private func marked(_ text: String, paragraph: Int) -> AttributedString {
        var marked = AttributedString(text)
        for range in TextSearch.ranges(of: find, in: text) {
            guard let run = Range(range, in: marked) else { continue }
            if current == TranscriptFind.Hit(paragraph: paragraph, range: range) {
                marked[run].backgroundColor = DesignTokens.Colors.slab
                marked[run].foregroundColor = DesignTokens.Colors.onSlab
            } else {
                marked[run].backgroundColor = DesignTokens.Colors.inkA20
            }
        }
        return marked
    }

    @ViewBuilder private func time(_ paragraph: Meeting.Paragraph) -> some View {
        let text = Text(TranscriptRender.timestamp(ms: paragraph.startMs))
            .font(Square.mono(11))
            .monospacedDigit()
            .foregroundStyle(DesignTokens.Colors.ink3)
        if let audio {
            Button { player.play(id: meeting.id, urls: audio, from: Double(paragraph.startMs) / 1000) } label: { text }
                .buttonStyle(.plain)
                .help("play from here")
                .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        } else {
            text
        }
    }
}

/// The system share menu, shown once under the view this sits behind when
/// it is given a file; `done` clears the file so the next click shows it again.
private struct SharePicker: NSViewRepresentable {
    let file: URL?
    let done: () -> Void

    final class Coordinator { var shown = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let file else { context.coordinator.shown = false; return }
        guard !context.coordinator.shown else { return }
        context.coordinator.shown = true
        // Out of the update pass: the menu runs its own tracking loop.
        Task { @MainActor in
            NSSharingServicePicker(items: [file]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            done()
        }
    }
}

/// A hook on the meeting's rail: its number, its name, how it went here
/// (a spinner while it runs) and ▷ to run it alone. The name opens the
/// hook on the hooks tab.
private struct HookRailLine: View {
    let number: Int
    let line: MeetingPage.HookLine
    /// nil for a hook no longer in settings, which can't run again.
    let run: (() -> Void)?
    let enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            SquareRunNumber(number: number)
            let notRun = if case .notRun = line.status { true } else { false }
            Button(action: edit) {
                Text(line.name).font(Square.mono(12)).foregroundStyle(notRun ? DesignTokens.Colors.ink2 : DesignTokens.Colors.ink)
                    .lineLimit(1).centredLetters(line.name, size: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(line.hookID == nil)
            .help("edit \(line.name)")
            switch line.status {
            case .running:
                SquareSpinner().frame(width: 12, height: 12)
            case .ran(let run):
                let state = run.failed ? "failed" : "done"
                Text(state).font(Square.mono(11)).foregroundStyle(run.failed ? DesignTokens.Colors.ink : DesignTokens.Colors.ink3)
                    .centredLetters(state, size: 11)
            case .notRun:
                Text("not run").font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3).centredLetters("not run", size: 11)
            }
            if let run {
                Button(action: run) { SquareIcon("akar-play", size: 9) }
                    .buttonStyle(SquareIconButtonStyle(side: 22))
                    .disabled(!enabled)
                    .help("run \(line.name)")
                    .accessibilityLabel("run \(line.name)")
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .frame(height: 28)
    }
    private func edit() {
        guard let hook = line.hookID else { return }
        AppState.shared.editHook = hook
        AppState.shared.settingsTab = .hooks
    }

}
