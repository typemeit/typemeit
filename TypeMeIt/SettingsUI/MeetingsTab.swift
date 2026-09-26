import AppKit
import SwiftUI

/// The meetings page (docs/meetings.md 7.11): every meeting by day, filtered
/// by where, who and when, with what records now in a band above. A row says
/// how its transcription stands; a click opens the meeting's own page.
struct MeetingsTab: View {
    /// Shows the settings group that holds the meeting settings.
    var showSettings: () -> Void = {}
    @State private var store = MeetingStore.shared
    @State private var coordinator = MeetingCoordinator.shared
    @State private var settings = Settings.shared
    @State private var appState = AppState.shared
    @State private var diarizer = DiarizerModelStore.shared
    @State private var search = ""
    /// The where filter: an app's name, or a channel.
    @State private var place: String?
    /// The who filter: meetings with everyone in it.
    @State private var people: Set<String> = []
    @State private var when = SquareWhen.any
    @State private var from = ""
    @State private var to = ""
    @State private var whereOpen = false
    @State private var whoOpen = false
    @State private var whenOpen = false
    @State private var selected: Set<UUID> = []
    /// The row a range is measured from: the last one whose box was clicked.
    @State private var anchor: UUID?
    /// Meetings whose stop was clicked, until their transcription lets go.
    @State private var stopping: Set<UUID> = []
    @State private var deletingPicked = false
    /// The meeting shown as its own page, or nil for the list.
    @State private var open: UUID?
    /// Re-reads the clock for the recording band's time.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        Group {
            if let id = open, let meeting = store.meeting(id) {
                MeetingPage(meeting: meeting) { open = nil }
            } else if store.meetings.isEmpty, coordinator.recording == nil {
                VStack(spacing: 0) {
                    SquarePageHeader(title: "meetings")
                    MeetingsFirstRun(record: { coordinator.recordRoom() }, showSettings: showSettings)
                }
            } else {
                list
            }
        }
        .onAppear(perform: reveal)
        .onChange(of: appState.revealMeeting) { _, _ in reveal() }
        .onChange(of: store.meetings.map(\.id)) { _, ids in
            if let id = open, !ids.contains(id) { open = nil }
            selected.formIntersection(ids)
        }
        .onChange(of: coordinator.transcribing?.id) { _, running in stopping = stopping.filter { $0 == running } }
    }

    /// The pill's `show` opens the meeting it names.
    private func reveal() {
        guard let id = appState.revealMeeting else { return }
        appState.revealMeeting = nil
        open = id
    }

    private var list: some View {
        let rows = filtered
        return VStack(alignment: .leading, spacing: 0) {
            SquarePageHeader(title: "meetings", count: counted(store.meetings.count, "meeting"), status: status,
                             linkTitle: "meeting settings", onLink: showSettings)
            toolbar(shown: rows.count)
            if let live = coordinator.recording { liveBand(live) }
            modelStatus
            if store.meetings.isEmpty {
                message { Text("nothing yet") }
            } else if rows.isEmpty {
                message {
                    HStack(spacing: 6) {
                        Text("no meetings match ·")
                        SquareLink(title: "clear the filters", size: 12, color: DesignTokens.Colors.ink2, action: clearFilters)
                    }
                }
            } else {
                MeetingColumns.head.padding(.horizontal, MeetingColumns.page)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(MeetingsTab.lines(rows)) { line in
                            switch line {
                            case .day(_, let day, let date, let total):
                                MeetingDayRow(day: day, date: date, total: total)
                            case .row(let meeting):
                                MeetingRow(meeting: meeting, picked: picked(meeting.id), picking: !selected.isEmpty,
                                           stopping: stopping.contains(meeting.id),
                                           open: { open = meeting.id },
                                           stop: {
                                               stopping.insert(meeting.id)
                                               coordinator.stopTranscribing(meeting.id)
                                           })
                            }
                        }
                    }
                    .padding(.horizontal, MeetingColumns.page)
                    .padding(.bottom, 20)
                }
            }
        }
        .onReceive(clock) { now = $0 }
    }

    private func message(@ViewBuilder _ text: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            text()
                .font(Square.mono(12))
                .foregroundStyle(DesignTokens.Colors.ink2)
                .padding(.top, 40)
                .padding(.leading, MeetingColumns.page + MeetingColumns.lead)
            Spacer(minLength: 0)
        }
    }

    /// Whether calls are asked about, and what the meetings take up.
    private var status: String {
        let asks = settings.meetingAsk ? "asks when a call starts" : "never asks"
        guard let usage = store.diskUsage else { return asks }
        return "\(asks) · \(ByteCountFormatter.string(fromByteCount: usage, countStyle: .file).lowercased())"
    }

    private func toolbar(shown: Int) -> some View {
        HStack(spacing: 8) {
            SquareField(placeholder: "search", text: $search, icon: "akar-search").frame(width: 220)
            SquareFilter(label: place ?? "where", active: place != nil, clear: { place = nil }, open: $whereOpen) {
                let items = whereItems
                SquareMenuList(items: items.map(\.item), minWidth: 232) { i in
                    place = items[i].value
                    whereOpen = false
                }
            }
            SquareFilter(label: people.isEmpty ? "who" : people.sorted().joined(separator: ", "), active: !people.isEmpty,
                         clear: { people = [] }, open: $whoOpen) {
                WhoMenu(people: $people, counts: MeetingsTab.personCounts(in: store.meetings))
            }
            SquareFilter(label: whenLabel, active: whenActive, clear: { when = .any; from = ""; to = "" }, open: $whenOpen) {
                SquareWhenPicker(when: $when, from: $from, to: $to)
            }
            Spacer(minLength: 0)
            if filtering, !store.meetings.isEmpty {
                Text("\(shown.formatted()) of \(store.meetings.count.formatted())")
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink2)
                Button("clear", action: clearFilters).buttonStyle(SquareButtonStyle(kind: .quiet, small: true))
            }
            if !selected.isEmpty {
                let doomed = selected.subtracting(coordinator.liveIDs)
                Button("delete \(selected.count)") { deletingPicked.toggle() }
                    .buttonStyle(SquareButtonStyle())
                    .squareConfirmDelete(isPresented: $deletingPicked, title: "delete \(counted(doomed.count, "meeting"))?",
                                         detail: SquareDeleteConfirm.gone(doomed.count)) {
                        store.delete(ids: doomed)
                        selected = []
                    }
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, MeetingColumns.page)
        .padding(.bottom, 14)
    }

    /// What records now: where, how loud each side is, the time so far, and
    /// stop. It names no one.
    private func liveBand(_ live: MeetingCoordinator.Live) -> some View {
        SquareLiveBand(place: live.kind == .room ? "the room" : store.meeting(live.id)?.app?.name.lowercased() ?? "a call",
                       time: SquareScrubber.clock(max(0, now.timeIntervalSince(live.started))),
                       you: Double(coordinator.levels.mic),
                       call: coordinator.levels.others.map(Double.init),
                       stop: { coordinator.stopMeeting() })
            .padding(.horizontal, MeetingColumns.page)
            .padding(.bottom, 12)
    }

    /// The speaker model, while it downloads or when it could not.
    @ViewBuilder private var modelStatus: some View {
        switch diarizer.state {
        case .downloading(let received, let total):
            let fraction = Double(received) / Double(max(total, 1))
            HStack(spacing: 12) {
                Text("downloading the speaker model · \(Int(fraction * 100))%")
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink2)
                SquareBar(fraction: fraction)
            }
            .padding(.horizontal, MeetingColumns.page + MeetingColumns.lead)
            .padding(.bottom, 12)
        case .verifying:
            Text("checking the speaker model")
                .font(Square.mono(11))
                .foregroundStyle(DesignTokens.Colors.ink2)
                .padding(.horizontal, MeetingColumns.page + MeetingColumns.lead)
                .padding(.bottom, 12)
        case .failed:
            HStack(spacing: 10) {
                SquareFailure(text: "the speaker model didn't download")
                Button("retry") { diarizer.download() }.buttonStyle(SquareButtonStyle(small: true))
            }
            .padding(.horizontal, MeetingColumns.page + MeetingColumns.lead)
            .padding(.bottom, 12)
        case .missing, .installed:
            EmptyView()
        }
    }

    // MARK: Filtering

    private var filtering: Bool {
        place != nil || !people.isEmpty || whenActive || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func clearFilters() {
        place = nil
        people = []
        when = .any
        from = ""
        to = ""
        search = ""
    }

    private var filtered: [Meeting] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let time = WhenFilter(when, from: from, to: to)
        return store.meetings.filter { m in
            if !MeetingsTab.matches(m, place: place, people: people) { return false }
            if !time.contains(m.started) { return false }
            if !q.isEmpty {
                let text = ([m.title, m.summary ?? ""] + m.speakers.map(\.name)).joined(separator: " ").lowercased()
                if !text.contains(q), !m.paragraphs.contains(where: { $0.text.lowercased().contains(q) }) { return false }
            }
            return true
        }
    }

    /// The meeting's app, as the list and the where filter name it.
    static func app(of meeting: Meeting) -> String {
        meeting.kind == .room ? "room" : meeting.app?.name.lowercased() ?? "call"
    }

    /// A huddle's channel, which the where filter lists under its app.
    static func channel(of meeting: Meeting) -> String? { meeting.names?.channel }

    /// Everyone in it but you, by the names they go by.
    static func others(in meeting: Meeting) -> [String] {
        meeting.speakers.filter { !$0.isYou }.map(\.name)
    }

    private var whereItems: [(value: String?, item: SquareMenuList.Item)] {
        MeetingsTab.placeItems(meetings: store.meetings, place: place)
    }

    /// "Any app", then each app by how much happened in it, its meetings'
    /// channels under it. A dictation counts towards the app it went to.
    static func placeItems(meetings: [Meeting], dictations: [HistoryEntry] = [], place: String?) -> [(value: String?, item: SquareMenuList.Item)] {
        var apps: [String: Int] = [:]
        var channels: [String: [String: Int]] = [:]
        for e in dictations { apps[HistoryTab.app(of: e), default: 0] += 1 }
        for m in meetings {
            let app = MeetingsTab.app(of: m)
            apps[app, default: 0] += 1
            if let channel = MeetingsTab.channel(of: m) { channels[app, default: [:]][channel, default: 0] += 1 }
        }
        var out: [(value: String?, item: SquareMenuList.Item)] = [
            (nil, SquareMenuList.Item(label: "any app", checked: place == nil, count: (meetings.count + dictations.count).formatted())),
        ]
        for (app, count) in apps.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            out.append((app, SquareMenuList.Item(label: app, checked: place == app, count: count.formatted())))
            for (channel, n) in (channels[app] ?? [:]).sorted(by: { $0.key < $1.key }) {
                out.append((channel, SquareMenuList.Item(label: channel, checked: place == channel, count: n.formatted(), indent: true)))
            }
        }
        return out
    }

    /// Everyone met, by how many meetings they were in.
    static func personCounts(in meetings: [Meeting]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for m in meetings {
            for name in Set(MeetingsTab.others(in: m)) { counts[name, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// Whether a meeting is in the where filter's app or channel, with
    /// everyone the who filter ticks.
    static func matches(_ m: Meeting, place: String?, people: Set<String>) -> Bool {
        if let place, app(of: m) != place, channel(of: m) != place { return false }
        return people.isEmpty || people.isSubset(of: Set(others(in: m)))
    }

    private var whenActive: Bool { WhenFilter(when, from: from, to: to).narrows }

    private var whenLabel: String { WhenFilter(when, from: from, to: to).label }

    // MARK: Rows

    enum Line: Identifiable {
        case day(id: Date, day: String, date: String, total: String)
        case row(Meeting)

        var id: String {
            switch self {
            case .day(let id, _, _, _): "day-\(id.timeIntervalSinceReferenceDate)"
            case .row(let meeting): meeting.id.uuidString
            }
        }
    }

    /// The meetings under a line for each day, newest first, the day saying
    /// how many there were and how long they ran.
    static func lines(_ rows: [Meeting], calendar: Calendar = .current) -> [Line] {
        var out: [Line] = []
        var i = rows.startIndex
        while i < rows.endIndex {
            let day = calendar.startOfDay(for: rows[i].started)
            var j = i
            while j < rows.endIndex, calendar.isDate(rows[j].started, inSameDayAs: day) { j += 1 }
            let same = rows[i..<j]
            let ms = same.reduce(0) { $0 + $1.durationMs }
            let label = HistoryTab.dayLabel(day, calendar: calendar)
            out.append(.day(id: day, day: label.day, date: label.date,
                            total: "\(counted(same.count, "meeting")) · \(MeetingsTab.length(ms))"))
            out.append(contentsOf: same.map(Line.row))
            i = j
        }
        return out
    }

    /// "11m", or "1h 12m" past the hour.
    static func length(_ ms: Int) -> String {
        let minutes = Int((Double(ms) / 60_000).rounded())
        return minutes >= 60 ? String(format: "%dh %02dm", minutes / 60, minutes % 60) : "\(minutes)m"
    }

    private func picked(_ id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { _ in select(id) })
    }

    private func select(_ id: UUID) {
        selected = HistorySelection.clicked(id, extending: NSEvent.modifierFlags.contains(.shift),
                                            anchor: anchor, in: filtered.map(\.id), selected: selected)
        anchor = id
    }
}

/// The list's columns: the select box, time, the meeting, who, where and
/// its length. The head, the days and the rows share them.
enum MeetingColumns {
    static let page: CGFloat = 20
    static let tick: CGFloat = 22
    static let time: CGFloat = 60
    static let who: CGFloat = 170
    static let place: CGFloat = 80
    static let length: CGFloat = 48
    static let gap: CGFloat = 16
    /// Between the select box and the row.
    static let edge: CGFloat = 4
    /// How far the columns sit inside the row's own edges.
    static let inset: CGFloat = 8
    static let trail: CGFloat = 12
    /// Where the time column starts, from the list's edge.
    static var lead: CGFloat { tick + edge + inset }

    static var head: some View {
        HStack(spacing: edge) {
            Color.clear.frame(width: tick, height: 1)
            HStack(spacing: gap) {
                Text("time").frame(width: time, alignment: .leading)
                Text("meeting").frame(maxWidth: .infinity, alignment: .leading)
                Text("who").frame(width: who, alignment: .leading)
                Text("where").frame(width: place, alignment: .leading)
                Text("length").frame(width: length, alignment: .trailing)
            }
            .padding(.leading, inset)
            .padding(.trailing, trail)
        }
        .font(Square.mono(11))
        .foregroundStyle(DesignTokens.Colors.ink3)
        .padding(.bottom, 8)
    }
}

/// A day in the list: an ink rule, the day under the time, its date under
/// the meetings, and how much it held under who, where and length.
private struct MeetingDayRow: View {
    let day: String
    let date: String
    let total: String

    var body: some View {
        HStack(spacing: MeetingColumns.edge) {
            Color.clear.frame(width: MeetingColumns.tick, height: 1)
            HStack(alignment: .firstTextBaseline, spacing: MeetingColumns.gap) {
                // "yesterday" is wider than the time column; it runs into the gap.
                Text(day)
                    .font(Square.mono(12, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.ink)
                    .fixedSize()
                    .frame(width: MeetingColumns.time, alignment: .leading)
                Text(date)
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(total)
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: MeetingColumns.who + MeetingColumns.place + MeetingColumns.length + 2 * MeetingColumns.gap, alignment: .trailing)
            }
            .padding(.leading, MeetingColumns.inset)
            .padding(.trailing, MeetingColumns.trail)
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
        .overlay(alignment: .top) { SquareRule(color: DesignTokens.Colors.ink) }
        .padding(.top, 6)
    }
}

/// A meeting in the list: its select box under the pointer, when, its title
/// over its summary or how its transcription stands, who was in it, where
/// and how long. A click on the rest opens its page.
private struct MeetingRow: View {
    let meeting: Meeting
    @Binding var picked: Bool
    /// Something is picked, so every box shows.
    let picking: Bool
    /// Its stop was clicked and the transcription is letting go.
    let stopping: Bool
    let open: () -> Void
    let stop: () -> Void
    @State private var coordinator = MeetingCoordinator.shared
    @State private var store = MeetingStore.shared
    @State private var diarizer = DiarizerModelStore.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: MeetingColumns.edge) {
            Toggle("select", isOn: $picked)
                .toggleStyle(SquareTickStyle(faint: true))
                .labelsHidden()
                .frame(width: MeetingColumns.tick)
                .opacity(hovering || picking || picked ? 1 : 0)
                .help(picked ? "deselect" : "select · shift-click for a range")
            HStack(alignment: .center, spacing: MeetingColumns.gap) {
                Text(meeting.started.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                    .font(Square.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .frame(width: MeetingColumns.time, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title)
                        .font(Square.sans(13.5))
                        .foregroundStyle(DesignTokens.Colors.ink)
                        .lineLimit(1)
                    state
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(whoLine)
                    .font(Square.sans(12))
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .lineLimit(1)
                    .frame(width: MeetingColumns.who, alignment: .leading)
                Text(MeetingsTab.app(of: meeting))
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .lineLimit(1)
                    .frame(width: MeetingColumns.place, alignment: .leading)
                Text(MeetingsTab.length(meeting.durationMs))
                    .font(Square.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.ink)
                    .frame(width: MeetingColumns.length, alignment: .trailing)
            }
            .padding(.leading, MeetingColumns.inset)
            .padding(.trailing, MeetingColumns.trail)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
        .background(hovering ? DesignTokens.Colors.inkA04 : .clear)
        .overlay(alignment: .top) { SquareRule() }
        .onHover { hovering = $0 }
    }

    /// Everyone else first, then you.
    private var whoLine: String {
        let others = MeetingsTab.others(in: meeting)
        return (others + (meeting.speakers.contains(where: \.isYou) ? ["you"] : [])).joined(separator: ", ")
    }

    /// The summary, or while it transcribes how far it has got and a stop,
    /// or what the meeting is waiting for.
    @ViewBuilder private var state: some View {
        if let run = coordinator.transcribing, run.id == meeting.id {
            HStack(spacing: 10) {
                Text(stopping ? "stopping…" : run.progress.label)
                    .font(Square.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.Colors.ink2)
                // Stopping takes effect between chunks, so only while there are chunks left.
                if case .transcribing = run.progress {
                    SquareBar(fraction: run.fraction)
                    if !stopping { stopButton }
                }
            }
        } else if coordinator.queued.contains(meeting.id) {
            HStack(spacing: 10) {
                Text("waiting to transcribe").font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink2)
                stopButton
            }
        } else if coordinator.summarising.contains(meeting.id) {
            Text("summarising").font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink2)
        } else if MeetingState.hasChips(meeting, coordinator: coordinator, store: store, diarizer: diarizer) {
            MeetingChips(meeting: meeting)
        } else if let summary = meeting.summary, !summary.isEmpty {
            Text(summary)
                .font(Square.sans(12))
                .foregroundStyle(DesignTokens.Colors.ink2)
                .lineLimit(1)
        }
    }

    /// A small cross in ink-3 that only shows an edge under the pointer.
    private var stopButton: some View {
        Button(action: stop) { SquareIcon("akar-cross", size: 7) }
            .buttonStyle(SquareIconButtonStyle(side: 18))
            .help("stop transcribing")
            .accessibilityLabel("stop transcribing")
    }
}

/// What a finished or stalled meeting still needs, as the list and the page
/// show it: transcribe one that was put off, add speakers, the failure and
/// retry, the missing speech model, an unavailable folder.
enum MeetingState {
    @MainActor
    static func hasChips(_ m: Meeting, coordinator: MeetingCoordinator, store: MeetingStore, diarizer: DiarizerModelStore) -> Bool {
        waitingForModel(m) || coordinator.isWaiting(m.id) || canAddSpeakers(m, coordinator: coordinator, diarizer: diarizer)
            || m.onlyYourSide || m.transcription.state == .failed || folderMissing(m, store: store)
    }

    static func waitingForModel(_ m: Meeting) -> Bool { m.transcription.state == .pending && !ModelStore.isInstalled }

    @MainActor
    static func canAddSpeakers(_ m: Meeting, coordinator: MeetingCoordinator, diarizer: DiarizerModelStore) -> Bool {
        m.isDone && m.transcription.diarizer == nil && !m.audioFiles.isEmpty && diarizer.state == .installed && !coordinator.liveIDs.contains(m.id)
    }

    @MainActor
    static func folderMissing(_ m: Meeting, store: MeetingStore) -> Bool { !m.published && m.isDone && !store.folderAvailable }
}

/// A meeting's chips: plain facts in tags, a failure in full ink, and the
/// one button each needs.
struct MeetingChips: View {
    let meeting: Meeting
    @State private var coordinator = MeetingCoordinator.shared
    @State private var store = MeetingStore.shared
    @State private var diarizer = DiarizerModelStore.shared

    var body: some View {
        let m = meeting
        let waitingForModel = MeetingState.waitingForModel(m)
        HStack(spacing: 6) {
            if !waitingForModel, coordinator.isWaiting(m.id) {
                Button("transcribe") { if let latest = store.meeting(m.id) { coordinator.enqueue(latest) } }
                    .buttonStyle(SquareButtonStyle(kind: .primary, small: true))
            }
            if MeetingState.canAddSpeakers(m, coordinator: coordinator, diarizer: diarizer) {
                Button("add speakers") { coordinator.transcribeAgain(m.id) }.buttonStyle(SquareButtonStyle(small: true))
            }
            if m.onlyYourSide { SquareTag(text: "only your side") }
            if m.transcription.state == .failed {
                SquareFailure(text: "transcription failed")
                Button("retry") { coordinator.retry(m.id) }.buttonStyle(SquareButtonStyle(small: true))
            }
            if waitingForModel {
                SquareTag(text: "waiting for the speech model")
                Button("download") { ModelStore.shared.download() }.buttonStyle(SquareButtonStyle(small: true))
            }
            if MeetingState.folderMissing(m, store: store) { SquareFailure(text: "meetings folder unavailable") }
        }
    }
}

/// The who filter's menu: a field to find someone, everyone met with how
/// many meetings they were in, ticked to narrow the list to meetings with
/// all of them.
struct WhoMenu: View {
    @Binding var people: Set<String>
    let counts: [(name: String, count: Int)]
    @State private var find = ""

    private static let width: CGFloat = 232

    var body: some View {
        let shown = counts.filter { find.isEmpty || $0.name.localizedCaseInsensitiveContains(find) }
        SquarePanel(padding: EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)) {
            VStack(alignment: .leading, spacing: 0) {
                SquareField(placeholder: "find someone", text: $find, icon: "akar-search")
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                SquareMenuLines(items: shown.map { SquareMenuList.Item(label: $0.name, checked: people.contains($0.name), count: $0.count.formatted()) }) { i in
                    let name = shown[i].name
                    if people.contains(name) { people.remove(name) } else { people.insert(name) }
                }
                Text("meetings with everyone you tick")
                    .font(Square.sans(11.5))
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
            .frame(width: WhoMenu.width)
        }
        .fixedSize()
    }
}

/// The page before the first meeting: what a call brings up, and the room
/// recorded by hand, with its shortcut once one is set.
private struct MeetingsFirstRun: View {
    let record: () -> Void
    let showSettings: () -> Void
    @State private var settings = Settings.shared

    private static let width: CGFloat = 680

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            Text("nothing recorded yet")
                .font(Square.mono(30))
                .tracking(-0.6)
                .foregroundStyle(DesignTokens.Colors.ink)
            HStack(alignment: .top, spacing: 40) {
                card("01", "on a call") {
                    // What a call brings up, to look at rather than click.
                    SquarePrompt(mark: .app("s"), message: Text("record this meeting?"), dismiss: "not now") {
                        Button("record") {}.buttonStyle(SquareButtonStyle(kind: .primary))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                card("02", "in a room") {
                    HStack(spacing: 12) {
                        Button(action: record) {
                            Label { Text("record the room") } icon: { Rectangle().frame(width: 8, height: 8) }
                        }
                        .buttonStyle(SquareButtonStyle(kind: .primary))
                        if let combo = settings.recordRoomShortcut {
                            HStack(spacing: 4) { ForEach(combo.caps, id: \.self) { SquareKeycap($0) } }
                        } else {
                            SquareLink(title: "set a shortcut", color: DesignTokens.Colors.ink2, action: showSettings)
                        }
                    }
                }
            }
        }
        .frame(width: MeetingsFirstRun.width, alignment: .leading)
        .padding(.horizontal, 60)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ number: String, _ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(number).font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3)
                Text(title).font(Square.mono(16)).foregroundStyle(DesignTokens.Colors.ink)
            }
            content()
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { SquareRule(color: DesignTokens.Colors.ink) }
    }
}

extension MeetingTranscriber.Progress {
    /// The line a meeting shows while its pass runs.
    var label: String {
        switch self {
        case .transcribing(let fraction): "transcribing · \(Int(fraction * 100))%"
        case .findingSpeakers: "finding speakers"
        case .summarising: "summarising"
        }
    }
}
