import AppKit
import SwiftUI

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
    @State private var title = ""
    @State private var titleFocused = true
    /// The speaker being renamed in the rail.
    @State private var naming: String?
    @State private var name = ""
    @State private var nameFocused = true
    /// The `.tmi` file the share menu is showing.
    @State private var sharing: URL?

    private static let railWidth: CGFloat = 272

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
                ScrollView { article }.frame(maxWidth: .infinity)
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
        .onAppear { coordinator.summarise(meeting.id) }
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
            Button {
                title = meeting.title
                titleFocused = true
                renaming.toggle()
            } label: {
                SquareIcon("akar-pencil", size: 14)
            }
            .buttonStyle(SquareIconButtonStyle())
            .help("rename")
            .accessibilityLabel("rename")
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
            VStack(alignment: .leading, spacing: 0) {
                SquareSubhead(text: "transcript", first: true)
                MeetingTranscript(meeting: meeting, audio: audioURLs)
            }
            .padding(.top, 26)
        }
        .padding(.top, 26)
        .padding(.leading, 44)
        .padding(.trailing, 40)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .frame(maxWidth: 520)
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
        let end = meeting.ended ?? meeting.started.addingTimeInterval(Double(meeting.durationMs) / 1000)
        return "\(day) · \(meeting.started.formatted(time))–\(end.formatted(time))"
    }

    /// How far its transcription has got, what it still needs, or its summary.
    @ViewBuilder private var state: some View {
        if let run = coordinator.transcribing, run.id == meeting.id {
            HStack(spacing: 12) {
                Text("transcribing · \(Int(run.fraction * 100))%")
                    .font(Square.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.ink2)
                SquareBar(fraction: run.fraction, width: 220)
            }
        } else if MeetingState.hasChips(meeting, coordinator: coordinator, store: store, diarizer: DiarizerModelStore.shared) {
            MeetingChips(meeting: meeting)
        } else if let summary = meeting.summary, !summary.isEmpty {
            Text(summary)
                .font(Square.sans(15))
                .lineSpacing(6)
                .foregroundStyle(DesignTokens.Colors.ink)
                .textSelection(.enabled)
                .frame(maxWidth: 560, alignment: .leading)
        } else if coordinator.summarising.contains(meeting.id) {
            Text("summarising…").font(Square.mono(12)).foregroundStyle(DesignTokens.Colors.ink3)
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
            }
            SquareSubhead(text: "where", first: meeting.speakers.isEmpty)
            Text(whereLine)
                .font(Square.mono(12))
                .foregroundStyle(DesignTokens.Colors.ink)
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

    /// A speaker, how much of the talking they did, and the name a click
    /// changes: return keeps it, esc gives up (docs/meetings.md 8.4).
    private func person(_ speaker: Meeting.Speaker) -> some View {
        let total = max(1, meeting.speakers.reduce(0) { $0 + $1.talkMs })
        let share = Double(speaker.talkMs) / Double(total)
        return HStack(spacing: 10) {
            Group {
                if naming == speaker.id {
                    SquareTextInput(placeholder: "name", text: $name, font: Square.appKitMono(12), focused: $nameFocused,
                                    onSubmit: {
                                        store.rename(speaker: speaker.id, to: name, in: meeting.id)
                                        naming = nil
                                    },
                                    onCancel: { naming = nil })
                        .overlay(alignment: .bottom) { SquareRule(color: DesignTokens.Colors.ink) }
                } else {
                    Button {
                        name = speaker.name
                        nameFocused = true
                        naming = speaker.id
                    } label: {
                        Text(speaker.name)
                            .font(Square.mono(12))
                            .foregroundStyle(DesignTokens.Colors.ink)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("rename")
                }
            }
            .frame(width: 72, alignment: .leading)
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
    }

    /// The app and its channel or call, the room, and who sent a shared one.
    private var whereLine: String {
        var parts: [String]
        if meeting.kind == .room {
            parts = ["the room"]
        } else {
            parts = [meeting.app?.name.lowercased() ?? "a call"]
            if let channel = meeting.names?.channel { parts.append(channel) } else if let call = meeting.names?.call { parts.append(call) }
        }
        if let from = meeting.sharedBy, !from.isEmpty { parts.append("from \(from.lowercased())") }
        return parts.joined(separator: " · ")
    }

    /// What ran on the meeting and what it came to, from what the meeting
    /// records about itself.
    private var processing: [(key: String, value: String, waiting: Bool)] {
        let t = meeting.transcription
        let running = coordinator.transcribing?.id == meeting.id
        var rows: [(key: String, value: String, waiting: Bool)] = []
        if running, let run = coordinator.transcribing {
            rows.append(("asr", "\(t.asr ?? "parakeet") · \(Int(run.fraction * 100))%", false))
        } else {
            rows.append(("asr", t.asr ?? "none yet", t.asr == nil))
        }
        rows.append(("speakers", t.diarizer ?? (meeting.isDone ? "none" : "waiting"), t.diarizer == nil))
        rows.append(("names from", MeetingPage.nameSource(meeting) ?? (meeting.isDone ? "none" : "waiting"), MeetingPage.nameSource(meeting) == nil))
        if meeting.kind == .call { rows.append(("echo", MeetingPage.echo(meeting.echo), meeting.echo == .notMeasured)) }
        if let took = t.tookMs, meeting.durationMs > 0 {
            rows.append(("transcribed", String(format: "%@ · %.2fx", MeetingPage.seconds(took), Double(took) / Double(meeting.durationMs)), false))
        }
        let summary = meeting.summary.map { _ in "apple intelligence" } ?? (coordinator.summarising.contains(meeting.id) ? "writing" : meeting.isDone ? "none" : "waiting")
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
        case .generated: "generated"
        case .roster: "from who was there"
        }
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

/// The transcript: each turn's speaker and time, and what they said. The
/// line playing is in full ink; a time, clicked, plays from there. Lazy: an
/// hour's meeting is hundreds of turns, and only those on screen are built.
private struct MeetingTranscript: View {
    let meeting: Meeting
    let audio: [URL]?
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
                ForEach(Array(meeting.paragraphs.enumerated()), id: \.offset) { i, paragraph in
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.speakerName(paragraph.speaker))
                                .font(Square.mono(12, weight: .medium))
                                .foregroundStyle(DesignTokens.Colors.ink)
                                .lineLimit(1)
                            time(paragraph)
                        }
                        .frame(width: 88, alignment: .leading)
                        Text(paragraph.text)
                            .font(Square.sans(14))
                            .lineSpacing(5)
                            .foregroundStyle(i == current ? DesignTokens.Colors.ink : DesignTokens.Colors.ink2)
                            .textSelection(.enabled)
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
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

/// Play or pause on the slab, everyone's turns as the scrubber, and the time
/// over the length.
private struct MeetingPlayer: View {
    let meeting: Meeting
    let urls: [URL]
    @State private var player = RecordingPlayer.shared

    var body: some View {
        let loaded = player.playing == meeting.id
        let running = loaded && !player.paused
        let total = loaded ? player.duration : Double(meeting.durationMs) / 1000
        // Ticks only while playing: each tick lays the lanes out again.
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
                if meeting.speakers.isEmpty {
                    SquareScrubber(fraction: total > 0 ? at / total : 0, seek: seek)
                } else {
                    SpeakerLanes(meeting: meeting, fraction: total > 0 ? at / total : 0, seek: seek)
                }
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

/// Who spoke when, a lane each, as the player's scrubber: a click or a drag
/// moves the playhead, told to the player once the pointer lifts. The
/// playhead inverts what it crosses, ink on an empty lane and paper across a
/// turn. Where no lane is filled, nobody was talking.
private struct SpeakerLanes: View {
    let meeting: Meeting
    let fraction: Double
    let seek: (Double) -> Void
    @State private var dragging: Double?

    private static let lane: CGFloat = 10
    private static let gap: CGFloat = 6
    /// The names' column, room for about twenty characters before a longer
    /// name is cut short with an ellipsis.
    private static let label: CGFloat = 128
    /// Kept clear between a name and its lane.
    private static let labelGap: CGFloat = 8
    /// How far the playhead reaches past the top and bottom lanes.
    private static let reach: CGFloat = 6

    var body: some View {
        let speakers = meeting.speakers
        let height = CGFloat(speakers.count) * (SpeakerLanes.lane + SpeakerLanes.gap) - SpeakerLanes.gap
        GeometryReader { geo in
            let track = max(geo.size.width - SpeakerLanes.label, 1)
            let shown = min(max(dragging ?? fraction, 0), 1)
            ZStack(alignment: .topLeading) {
                VStack(spacing: SpeakerLanes.gap) {
                    ForEach(speakers) { speaker in
                        HStack(spacing: 0) {
                            Text(speaker.name)
                                .font(Square.mono(10))
                                .foregroundStyle(DesignTokens.Colors.ink3)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.trailing, SpeakerLanes.labelGap)
                                .frame(width: SpeakerLanes.label, alignment: .leading)
                            turns(of: speaker.id).frame(height: SpeakerLanes.lane)
                        }
                    }
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height + 2 * SpeakerLanes.reach)
                    .offset(x: SpeakerLanes.label + track * shown - 1, y: -SpeakerLanes.reach)
                    .blendMode(.difference)
                    .allowsHitTesting(false)
            }
            .compositingGroup()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = min(max(($0.location.x - SpeakerLanes.label) / track, 0), 1) }
                .onEnded { _ in
                    if let dragging { seek(dragging) }
                    dragging = nil
                })
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("position")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }

    /// One speaker's turns along the meeting, in ink on an ink-a04 lane.
    private func turns(of speaker: String) -> some View {
        let paragraphs = meeting.paragraphs.filter { $0.speaker == speaker }
        let total = CGFloat(max(meeting.durationMs, 1))
        return Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(DesignTokens.Colors.inkA04))
            for p in paragraphs {
                let x = size.width * CGFloat(p.startMs) / total
                let width = max(1, size.width * CGFloat(p.endMs - p.startMs) / total)
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(DesignTokens.Colors.ink))
            }
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
