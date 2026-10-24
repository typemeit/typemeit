import SwiftUI

/// The time-of-day half of the when filter, "09:00" to "17:30", either end
/// left open. A window that ends before it starts runs across midnight.
struct TimeOfDayWindow {
    let from: Int?
    let to: Int?

    /// Nil when neither end reads as a time.
    init?(from: String, to: String) {
        self.from = TimeOfDayWindow.minutes(from)
        self.to = TimeOfDayWindow.minutes(to)
        if self.from == nil, self.to == nil { return nil }
    }

    /// Minutes into the day of "HH:mm".
    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let t = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if let from, let to, from > to { return t >= from || t <= to }
        if let from, t < from { return false }
        if let to, t > to { return false }
        return true
    }

    var label: String {
        let text = { (m: Int) in String(format: "%02d:%02d", m / 60, m % 60) }
        return "\(from.map(text) ?? "00:00")–\(to.map(text) ?? "23:59")"
    }
}

/// The when filter as a test on dates: the days it covers and the time of
/// day, worked out once for a pass over a list.
struct WhenFilter {
    let when: SquareWhen
    let window: TimeOfDayWindow?
    private let span: ClosedRange<Date>?
    private let calendar: Calendar

    init(_ when: SquareWhen, from: String, to: String, today: Date = .now, calendar: Calendar = .current) {
        self.when = when
        window = TimeOfDayWindow(from: from, to: to)
        span = when.span(today: today, calendar: calendar)
        self.calendar = calendar
    }

    /// Whether it narrows a list at all.
    var narrows: Bool { span != nil || window != nil }

    /// Its chip's name: "when", or the days and time of day it is set to.
    var label: String {
        guard when != .any else { return window?.label ?? "when" }
        return [when.label, window?.label].compactMap { $0 }.joined(separator: " · ")
    }

    func contains(_ date: Date) -> Bool {
        if let span {
            let day = calendar.startOfDay(for: date)
            if day < span.lowerBound || day > span.upperBound { return false }
        }
        return window?.contains(date, calendar: calendar) ?? true
    }
}

/// What the list works out from each dictation, kept until the history
/// changes rather than redone on every keystroke: its words for the day
/// totals, and its text and transcript lowercased for search.
@MainActor private final class HistoryIndex {
    private var revision = -1
    private var words: [UUID: Int] = [:]
    private var texts: [UUID: [UInt8]] = [:]
    private var listKey: ListKey?
    private var list: (rows: [HistoryEntry], lines: [DayLine<HistoryEntry>]) = ([], [])

    /// What the list shows depends on, besides the history.
    struct ListKey: Equatable {
        let app: String?
        let askedClaude: Bool?
        let when: SquareWhen
        let from: String
        let to: String
        let search: String
        /// Today and yesterday name their day lines, and the presets move on.
        let today: Date
    }

    private func current(_ store: Store) {
        guard revision != store.revision else { return }
        revision = store.revision
        words = [:]
        texts = [:]
        listKey = nil
    }

    /// The rows the filters leave and their day lines, kept until the history
    /// or the filters change: opening a dictation or a menu redraws the page
    /// without changing either.
    func list(for key: ListKey, store: Store, compute: () -> (rows: [HistoryEntry], lines: [DayLine<HistoryEntry>])) -> (rows: [HistoryEntry], lines: [DayLine<HistoryEntry>]) {
        current(store)
        if key != listKey {
            list = compute()
            listKey = key
        }
        return list
    }

    func words(in entry: HistoryEntry, store: Store) -> Int {
        current(store)
        if let n = words[entry.id] { return n }
        let n = entry.wordCount
        words[entry.id] = n
        return n
    }

    /// Whether the entry's text or transcript holds `query`, lowercased UTF-8.
    func matches(_ entry: HistoryEntry, _ query: [UInt8], store: Store) -> Bool {
        current(store)
        let text: [UInt8]
        if let known = texts[entry.id] {
            text = known
        } else {
            text = Array("\(entry.displayText)\n\(entry.transcript)".lowercased().utf8)
            texts[entry.id] = text
        }
        return text.withUnsafeBytes { hay in
            query.withUnsafeBytes { q in memmem(hay.baseAddress, hay.count, q.baseAddress, q.count) != nil }
        }
    }
}

/// History: every dictation by day, filtered by app, time and words. A row
/// copies or deletes in place, and a click opens the dictation's own page.
struct HistoryTab: View {
    /// Shows the settings group that keeps history.
    var showSettings: () -> Void = {}
    @State private var store = Store.shared
    @State private var settings = Settings.shared
    @State private var appState = AppState.shared
    @State private var search = ""
    @State private var app: String?
    @State private var when = SquareWhen.any
    @State private var from = ""
    @State private var to = ""
    @State private var appOpen = false
    @State private var whenOpen = false
    /// Only dictations that asked Claude (true), only typed ones (false), or both.
    @State private var askedClaude: Bool?
    @State private var claudeOpen = false
    @State private var selection = ListSelection()
    /// The row whose copy ran last, which shows a check for it.
    @State private var copied: UUID?
    /// The dictation shown as its own page, or nil for the list.
    @State private var open: UUID?
    @State private var index = HistoryIndex()
    @State private var deletingPicked = false

    var body: some View {
        let entry = open.flatMap { id in store.history.first { $0.id == id } }
        ZStack {
            // Kept under an open dictation, so going back finds it as it was
            // instead of building it again.
            list
                .opacity(entry == nil ? 1 : 0)
                .allowsHitTesting(entry == nil)
                .disabled(entry != nil)
                .accessibilityHidden(entry != nil)
            if let entry { DictationPage(entry: entry) { open = nil } }
        }
        .onAppear(perform: reveal)
        .onChange(of: appState.revealDictation) { _, _ in reveal() }
        // The sidebar's dictations: back to every dictation.
        .onChange(of: appState.sidebarClicks[.history]) { _, _ in
            open = nil
            search = ""
            app = nil
            askedClaude = nil
            when = .any
            from = ""
            to = ""
        }
    }

    /// The asking pill's open shows the dictation it names.
    private func reveal() {
        guard let id = appState.revealDictation else { return }
        appState.revealDictation = nil
        open = id
    }

    private var list: some View {
        let key = HistoryIndex.ListKey(app: app, askedClaude: askedClaude, when: when, from: from, to: to, search: search,
                                       today: Calendar.current.startOfDay(for: .now))
        let (rows, lines) = index.list(for: key, store: store) {
            let rows = filtered
            return (rows, HistoryTab.lines(rows, wordsIn: { index.words(in: $0, store: store) }))
        }
        return VStack(alignment: .leading, spacing: 0) {
            SquarePageHeader(title: "dictations", count: counted(store.history.count, "dictation"),
                             status: KeepLimit.dictations.status(settings.historyLimit),
                             linkTitle: "history settings", onLink: showSettings)
            toolbar
            if rows.isEmpty {
                Text(store.history.isEmpty ? "nothing yet" : "no matches")
                    .font(Square.mono(12))
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .padding(.top, 40)
                    .padding(.leading, SquareListColumns.page + SquareListColumns.lead)
                Spacer(minLength: 0)
            } else {
                HistoryColumns.head.padding(.horizontal, SquareListColumns.page)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            switch line {
                            case .day(_, let day, let date, let total):
                                SquareDayHeader(day: day, date: date, total: total, totalWidth: HistoryColumns.total, trailing: HistoryColumns.trailing)
                            case .row(let entry):
                                HistoryRow(entry: entry, picked: $selection.box(entry.id) { filtered.map(\.id) },
                                           picking: !selection.picked.isEmpty, copied: copied == entry.id,
                                           open: { open = entry.id },
                                           copy: { Output.copyToClipboard(entry.displayText); copied = entry.id },
                                           delete: { store.delete(id: entry.id); selection.picked.remove(entry.id) })
                            }
                        }
                    }
                    .padding(.horizontal, SquareListColumns.page)
                    .padding(.bottom, 20)
                }
            }
        }
        .onChange(of: store.history.map(\.id)) { _, ids in selection.picked.formIntersection(ids) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            SquareField(placeholder: "search", text: $search, icon: "akar-search").frame(width: 260)
            SquareFilter(label: app ?? "app", active: app != nil, clear: { app = nil }, open: $appOpen) {
                let items = appItems
                SquareMenuList(items: items.map(\.item), minWidth: 232) { i in
                    app = items[i].value
                    appOpen = false
                }
            }
            SquareFilter(label: whenLabel, active: whenActive, clear: { when = .any; from = ""; to = "" }, open: $whenOpen) {
                SquareWhenPicker(when: $when, from: $from, to: $to)
            }
            SquareFilter(label: claudeItems.first { $0.value == askedClaude && askedClaude != nil }?.item.label ?? "claude",
                         active: askedClaude != nil, clear: { askedClaude = nil }, open: $claudeOpen) {
                let items = claudeItems
                SquareMenuList(items: items.map(\.item), minWidth: 232) { i in
                    askedClaude = items[i].value
                    claudeOpen = false
                }
            }
            Spacer(minLength: 0)
            if !selection.picked.isEmpty {
                Button("delete \(selection.picked.count)") { deletingPicked.toggle() }
                    .buttonStyle(SquareButtonStyle())
                    .squareConfirmDelete(isPresented: $deletingPicked, title: "delete \(counted(selection.picked.count, "dictation"))?",
                                         detail: SquareDeleteConfirm.gone(selection.picked.count)) {
                        store.delete(ids: selection.picked)
                        selection.picked = []
                    }
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, SquareListColumns.page)
        .padding(.bottom, 14)
    }

    // MARK: Filtering

    private var filtered: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let time = WhenFilter(when, from: from, to: to)
        let query = Array(q.utf8)
        return store.history.reversed().filter { e in
            if let app, HistoryTab.app(of: e) != app { return false }
            if let askedClaude, (e.question != nil) != askedClaude { return false }
            if !time.contains(e.timestamp) { return false }
            if !query.isEmpty, !index.matches(e, query, store: store) { return false }
            return true
        }
    }

    static func app(of entry: HistoryEntry) -> String { entry.appName?.lowercased() ?? "unknown" }

    /// Every dictation, those that asked Claude by name, and those typed.
    private var claudeItems: [(value: Bool?, item: SquareMenuList.Item)] {
        let asked = store.history.filter { $0.question != nil }.count
        return [(nil, SquareMenuList.Item(label: "any", checked: askedClaude == nil, count: store.history.count.formatted())),
                (true, SquareMenuList.Item(label: "asked claude", checked: askedClaude == true, count: asked.formatted())),
                (false, SquareMenuList.Item(label: "typed", checked: askedClaude == false, count: (store.history.count - asked).formatted()))]
    }

    /// "Any app", then each app by how many dictations went to it.
    private var appItems: [(value: String?, item: SquareMenuList.Item)] {
        var counts: [String: Int] = [:]
        for e in store.history { counts[HistoryTab.app(of: e), default: 0] += 1 }
        let apps = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return [(nil, SquareMenuList.Item(label: "any app", checked: app == nil, count: store.history.count.formatted()))]
            + apps.map { (Optional($0.key), SquareMenuList.Item(label: $0.key, checked: app == $0.key, count: $0.value.formatted())) }
    }

    private var whenActive: Bool { WhenFilter(when, from: from, to: to).narrows }

    private var whenLabel: String { WhenFilter(when, from: from, to: to).label }

    // MARK: Rows

    /// The rows under a line for each day, newest first, the day saying how
    /// much it held.
    static func lines(_ rows: [HistoryEntry], wordsIn: (HistoryEntry) -> Int = \.wordCount,
                      calendar: Calendar = .current) -> [DayLine<HistoryEntry>] {
        DayLine.lines(rows, on: \.timestamp, total: { day in
            "\(counted(day.count, "dictation")) · \(counted(day.reduce(0) { $0 + wordsIn($1) }, "word"))"
        }, calendar: calendar)
    }

    /// "today" over "thursday 24 september"; an older day by its weekday,
    /// over its date.
    nonisolated static func dayLabel(_ day: Date, calendar: Calendar = .current) -> (day: String, date: String) {
        let full = day.formatted(.dateTime.weekday(.wide).day().month(.wide)).lowercased()
        if calendar.isDateInToday(day) { return ("today", full) }
        if calendar.isDateInYesterday(day) { return ("yesterday", full) }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        let date = sameYear ? day.formatted(.dateTime.day().month(.wide)) : day.formatted(.dateTime.day().month(.wide).year())
        return (day.formatted(.dateTime.weekday(.wide)).lowercased(), date.lowercased())
    }
}

/// History's own columns beside the shared ones: its app, what changed and
/// its words, and a copy and a delete at the end. The head, the days and the
/// rows share them.
enum HistoryColumns {
    static let app: CGFloat = 116
    static let changes: CGFloat = 64
    static let words: CGFloat = 52
    static let action: CGFloat = 26
    /// Between the words and the first action's box, whose own margin makes
    /// up the rest of a column's gap. The two actions sit box to box.
    static let actionLead: CGFloat = 8
    /// What the two actions take at the end of a row.
    static var actions: CGFloat { actionLead + action * 2 }
    /// The select box and the actions are centred on the first line of the
    /// row, where its words are: this far above the line's baseline.
    static let lineMiddle = Square.appKitMono(12).capHeight / 2
    /// The head and the days leave the actions' room at the end.
    static var trailing: CGFloat { SquareListColumns.edge + actions + SquareListColumns.inset }
    /// A day's total sits over the app, the changes and the words.
    static var total: CGFloat { app + SquareListColumns.gap + changes + SquareListColumns.gap + words }

    static var head: some View {
        SquareListHead(trailing: trailing) {
            Text("time").frame(width: SquareListColumns.time, alignment: .leading)
            Text("dictation").frame(maxWidth: .infinity, alignment: .leading)
            Text("app").frame(width: app, alignment: .leading)
            Text("changes").frame(width: changes, alignment: .trailing)
            Text("words").frame(width: words, alignment: .trailing)
        }
    }
}

/// A dictation in the list: its select box under the pointer, when, what was
/// typed, where and how many words; copy and delete at the end. A click on
/// the rest opens its page.
private struct HistoryRow: View {
    let entry: HistoryEntry
    @Binding var picked: Bool
    /// Something is picked, so every box shows.
    let picking: Bool
    let copied: Bool
    let open: () -> Void
    let copy: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @State private var deleting = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Toggle("select", isOn: $picked)
                .toggleStyle(SquareTickStyle(faint: true))
                .labelsHidden()
                .frame(width: SquareListColumns.tick)
                .opacity(hovering || picking || picked ? 1 : 0)
                .help(picked ? "deselect" : "select · shift-click for a range")
                .onFirstLine()
                .padding(.trailing, SquareListColumns.edge)
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: SquareListColumns.gap) {
                    Text(entry.timestamp.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                        .font(Square.mono(12))
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Colors.ink2)
                        .frame(width: SquareListColumns.time, alignment: .leading)
                    Text(entry.displayText)
                        .font(Square.sans(13.5))
                        .lineSpacing(2)
                        .lineLimit(2)
                        .foregroundStyle(DesignTokens.Colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(HistoryTab.app(of: entry)).lineLimit(1)
                        if entry.edited != nil { SquareTag(text: "edited") }
                        if entry.question != nil { SquareTag(text: "claude") }
                    }
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .frame(width: HistoryColumns.app, alignment: .leading)
                    HStack(spacing: 6) { CharDelta(heard: entry.transcript, typed: entry.displayText) }
                        .font(Square.mono(11))
                        .frame(width: HistoryColumns.changes, alignment: .trailing)
                    Text(entry.wordCount.formatted())
                        .font(Square.mono(12))
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Colors.ink)
                        .frame(width: HistoryColumns.words, alignment: .trailing)
                }
                .padding(.leading, SquareListColumns.inset)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 0) {
                Button(action: copy) { SquareIcon(copied ? "akar-check" : "akar-copy", size: copied ? 12 : 14) }
                    .buttonStyle(SquareIconButtonStyle(side: HistoryColumns.action))
                    .help("copy")
                    .accessibilityLabel("copy")
                Button { deleting.toggle() } label: { SquareIcon("akar-trash-can", size: 14) }
                    .buttonStyle(SquareIconButtonStyle(side: HistoryColumns.action))
                    .help("delete")
                    .accessibilityLabel("delete")
                    .squareConfirmDelete(isPresented: $deleting, title: "delete this dictation?", delete: delete)
            }
            .onFirstLine()
            .padding(.leading, HistoryColumns.actionLead)
        }
        .padding(.trailing, SquareListColumns.inset)
        .background(hovering ? DesignTokens.Colors.inkA04 : .clear)
        .overlay(alignment: .top) { SquareRule() }
        .onHover { hovering = $0 }
    }
}

private extension View {
    /// Centres a box on the first line of a history row, however many lines
    /// the dictation runs to.
    func onFirstLine() -> some View {
        alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + HistoryColumns.lineMiddle }
    }
}
