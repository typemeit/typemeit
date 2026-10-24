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
    @State private var copied = false
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
            if let urls = audioURLs {
                MeetingPlayer(meeting: meeting, urls: urls)
            } else {
                Text("no audio kept")
                    .font(Square.mono(12))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { SquareRule() }
            }
        }
        // Playback belongs to the page: leaving it stops it.
        .onDisappear { if player.playing == meeting.id { player.stop() } }
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
        HStack(spacing: 6) {
            Button(action: back) {
                Label {
                    Text("meetings")
                } icon: {
                    SquareIcon("akar-chevron-down", size: 10).rotationEffect(.degrees(90))
                }
            }
            .buttonStyle(SquareButtonStyle(kind: .quiet))
            // Esc in a field gives up the edit, not the page.
            .keyboardShortcut(renaming || naming != nil ? nil : .cancelAction)
            Spacer(minLength: 0)
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
            Button {
                Output.copyToClipboard(meeting.transcriptText)
                copied = true
            } label: {
                SquareIcon(copied ? "akar-check" : "akar-copy", size: copied ? 12 : 14)
            }
            .buttonStyle(SquareIconButtonStyle())
            .disabled(meeting.paragraphs.isEmpty)
            .help("copy the transcript")
            .accessibilityLabel("copy the transcript")
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
            if meeting.isDone, !meeting.paragraphs.isEmpty, !live, coordinator.hooksReady {
                let running = coordinator.runningHooks[meeting.id] != nil
                Button(running ? "running hooks…" : "run hooks") { coordinator.runHooks(meeting.id) }
                    .buttonStyle(SquareButtonStyle(kind: .quiet))
                    .disabled(running)
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
        .padding(.top, 12)
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { SquareRule() }
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
        withAnimation(.easeOut(duration: DesignTokens.Duration.n2)) { proxy.scrollTo(all[hit].paragraph, anchor: .center) }
    }

    /// While the audio is kept, it can go on its own and the transcript stay.
    private var deleteConfirm: some View {
        let audio = audioURLs != nil
        return SquareConfirm(title: "delete this meeting?",
                             detail: audio ? "it has \(MeetingsTab.length(meeting.durationMs)) of audio." : nil,
                             width: 300) {
            Button("cancel") { deleting = false }.buttonStyle(SquareButtonStyle())
            if audio {
                Button("audio only") {
                    if player.playing == meeting.id { player.stop() }
                    store.deleteAudio(meeting.id)
                    deleting = false
                }
                .buttonStyle(SquareButtonStyle())
            }
            Button(audio ? "everything" : "delete") {
                if player.playing == meeting.id { player.stop() }
                deleting = false
                store.delete(ids: [meeting.id])
                back()
            }
            .buttonStyle(SquareButtonStyle(kind: .primary))
        }
    }

    // MARK: Article

    private var article: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleView
            Text(dateLine)
                .font(Square.mono(12))
                .foregroundStyle(DesignTokens.Colors.ink2)
                .padding(.top, 10)
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

    /// What the hooks run on the meeting said, oldest first, and a line
    /// while more are running.
    /// Claude answering a question asked in this meeting, live.
    @ViewBuilder private var asking: some View {
        if let asked = coordinator.askingIn, asked.meeting == meeting.id, let runID = asked.question.runID {
            ClaudeRunOutput(id: runID)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 26)
        }
    }

    @ViewBuilder private var hooks: some View {
        let current = coordinator.runningHooks[meeting.id]
        let runs = meeting.hookRuns ?? []
        if !runs.isEmpty || current != nil {
            VStack(alignment: .leading, spacing: 0) {
                SquareSubhead(text: "hooks", first: true)
                ForEach(runs, id: \.id) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text(run.name).font(Square.mono(12, weight: .medium)).foregroundStyle(DesignTokens.Colors.ink2)
                            Text(run.ranAt.formatted(date: .abbreviated, time: .shortened))
                                .font(Square.mono(11))
                                .foregroundStyle(DesignTokens.Colors.ink3)
                        }
                        ClaudeRunOutput(id: run.id, kept: .init(prompt: run.prompt, answer: run.output, failed: run.failed, sessionID: run.sessionID))
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }
                if let current {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(current.name).font(Square.mono(12, weight: .medium)).foregroundStyle(DesignTokens.Colors.ink2)
                        ClaudeRunOutput(id: current.runID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }
            }
            .padding(.top, 26)
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
            VStack(spacing: 0) {
                ForEach(processing, id: \.key) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.key).foregroundStyle(DesignTokens.Colors.ink3)
                        Spacer(minLength: 0)
                        Text(row.value)
                            .foregroundStyle(row.waiting ? DesignTokens.Colors.ink3 : DesignTokens.Colors.ink)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(Square.mono(11))
                    .monospacedDigit()
                    .padding(.vertical, 5)
                    .overlay(alignment: .top) { SquareRule() }
                }
            }
            .overlay(alignment: .bottom) { SquareRule() }
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
    private var processing: [(key: String, value: String, waiting: Bool)] {
        let t = meeting.transcription
        let running = coordinator.transcribing?.id == meeting.id
        var rows: [(key: String, value: String, waiting: Bool)] = []
        if running, let run = coordinator.transcribing {
            rows.append(("asr", "\(t.asr ?? ModelStore.version) · \(Int(run.fraction * 100))%", false))
        } else {
            rows.append(("asr", t.asr.map { MeetingPage.timed($0, t.asrMs) } ?? "none yet", t.asr == nil))
        }
        let stage = running ? coordinator.transcribing?.progress : nil
        rows.append(("speakers", t.diarizer.map { MeetingPage.timed(DiarizerModelStore.label(of: $0), t.speakersMs) }
            ?? (stage == .findingSpeakers ? "finding" : meeting.isDone ? "none" : "waiting"), t.diarizer == nil))
        rows.append(("names from", MeetingPage.nameSource(meeting) ?? (meeting.isDone ? "none" : "waiting"), MeetingPage.nameSource(meeting) == nil))
        if meeting.kind == .call { rows.append(("echo", MeetingPage.echo(meeting.echo), meeting.echo == .notMeasured)) }
        if let took = t.tookMs, meeting.durationMs > 0 {
            rows.append(("transcribed", "\(MeetingPage.seconds(took)) · \(timesFaster(audioMs: meeting.durationMs, tookMs: took))", false))
        }
        let writing = coordinator.summarising.contains(meeting.id) || stage == .summarising
        let summary = meeting.summary.map { _ in MeetingPage.timed("apple intelligence", t.summaryMs) } ?? (writing ? "writing" : meeting.isDone ? "none" : "waiting")
        rows.append(("summary", summary, meeting.summary == nil))
        rows.append(("title", MeetingPage.titleSource(meeting.titleSource), false))
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
        ms.map { "\(what) · \(seconds($0))" } ?? what
    }

    private static func seconds(_ ms: Int) -> String {
        let s = Int((Double(ms) / 1000).rounded())
        return s >= 60 ? String(format: "%dm %02ds", s / 60, s % 60) : "\(s)s"
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
            LazyVStack(alignment: .leading, spacing: 0) {
                if meeting.paragraphs.isEmpty {
                    Text(meeting.transcription.state == .done ? "nothing was said" : "not transcribed yet")
                        .font(Square.sans(14))
                        .foregroundStyle(DesignTokens.Colors.ink3)
                }
                ForEach(TranscriptRender.entries(meeting), id: \.self) { entry in
                    switch entry {
                    case .paragraph(let i): turn(i, current: current)
                    case .question(let i): question(meeting.questions?[i])
                    }
                }
            }
        }
    }

    private func turn(_ i: Int, current: Int?) -> some View {
        let paragraph = meeting.paragraphs[i]
        return HStack(alignment: .firstTextBaseline, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                speaker(paragraph.speaker)
                time(paragraph)
            }
            .frame(width: 88, alignment: .leading)
            Text(marked(paragraph.text, paragraph: i))
                .font(Square.sans(14))
                .lineSpacing(5)
                .foregroundStyle(i == current ? DesignTokens.Colors.ink : DesignTokens.Colors.ink2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .id(i)
    }

    /// A question offered to Claude: when it was heard, and the answer, or
    /// what the user did instead of asking.
    @ViewBuilder private func question(_ question: Meeting.Question?) -> some View {
        if let question {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("claude")
                        .font(Square.mono(12, weight: .medium))
                        .foregroundStyle(DesignTokens.Colors.ink2)
                    Text(TranscriptRender.timestamp(ms: question.atMs))
                        .font(Square.mono(11))
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Colors.ink3)
                }
                .frame(width: 88, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    if question.result != .asked || question.answer == nil && question.runID == nil {
                        Text(question.text)
                            .font(Square.mono(13))
                            .foregroundStyle(question.result == .asked ? DesignTokens.Colors.ink : DesignTokens.Colors.ink3)
                    }
                    if question.result == .asked, let answer = question.answer {
                        ClaudeRunOutput(id: question.runID ?? UUID(), kept: .init(prompt: question.text, answer: answer, failed: false, sessionID: question.sessionID))
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
            }
            .padding(.vertical, 10)
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
        for range in TranscriptFind.ranges(of: find, in: text) {
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

/// Play or pause on the slab, the scrubber, and the time over the length.
private struct MeetingPlayer: View {
    let meeting: Meeting
    let urls: [URL]
    @State private var player = RecordingPlayer.shared

    var body: some View {
        let loaded = player.playing == meeting.id
        let running = loaded && !player.paused
        let total = loaded ? player.duration : Double(meeting.durationMs) / 1000
        // Ticks only while playing.
        TimelineView(.animation(minimumInterval: 0.1, paused: !running)) { _ in
            let at = loaded ? player.currentTime : 0
            let seek = { (fraction: Double) in
                if loaded { player.seek(to: fraction * total) } else { player.play(id: meeting.id, urls: urls, from: fraction * total) }
            }
            HStack(spacing: 18) {
                Button {
                    if running { player.pause() } else { player.play(id: meeting.id, urls: urls) }
                } label: {
                    SquareIcon(running ? "akar-pause" : "akar-play", size: 14)
                }
                .buttonStyle(SquarePlayButtonStyle())
                .help(running ? "pause" : "play")
                .accessibilityLabel(running ? "pause" : "play")
                SquareScrubber(fraction: total > 0 ? at / total : 0, seek: seek)
                HStack(spacing: 0) {
                    Text(TranscriptRender.timestamp(ms: Int(at * 1000)))
                    Text(" / \(TranscriptRender.timestamp(ms: Int(total * 1000)))").foregroundStyle(DesignTokens.Colors.ink3)
                }
                .font(Square.mono(12))
                .monospacedDigit()
            }
        }
        .padding(.top, 14)
        .padding(.leading, 20)
        .padding(.trailing, 24)
        .padding(.bottom, 16)
        .overlay(alignment: .top) { SquareRule(color: DesignTokens.Colors.ink) }
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
