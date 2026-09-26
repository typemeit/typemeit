import SwiftUI

/// What a click on a row's box does to the selection. A plain click turns that
/// one row on or off; shift-click takes every row between the last box clicked
/// and this one, so a run of dictations can be deleted without clicking each
/// of them. The range is measured over the rows as they are listed, which
/// means it crosses the day headings they are grouped under and never reaches
/// a row the search has hidden. Shift only ever adds, so several runs can be
/// gathered up before deleting. An anchor that is no longer listed — the
/// search moved on, or the row was deleted — leaves shift with nothing to
/// measure from, and the click is the plain one.
enum HistorySelection {
    static func clicked(_ id: UUID, extending: Bool, anchor: UUID?, in rows: [UUID],
                        selected: Set<UUID>) -> Set<UUID> {
        if extending, let anchor,
           let from = rows.firstIndex(of: anchor), let to = rows.firstIndex(of: id) {
            return selected.union(rows[min(from, to)...max(from, to)])
        }
        var out = selected
        if out.contains(id) { out.remove(id) } else { out.insert(id) }
        return out
    }
}

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

/// History: every dictation by day, filtered by app, time and words. A row
/// copies or deletes in place, and a click opens the dictation's own page.
struct HistoryTab: View {
    /// Shows the settings group that keeps history.
    var showSettings: () -> Void = {}
    @State private var store = Store.shared
    @State private var settings = Settings.shared
    @State private var search = ""
    @State private var app: String?
    @State private var when = SquareWhen.any
    @State private var from = ""
    @State private var to = ""
    @State private var appOpen = false
    @State private var whenOpen = false
    @State private var selected: Set<UUID> = []
    /// The row a range is measured from: the last one whose box was clicked.
    @State private var anchor: UUID?
    /// The row whose copy ran last, which shows a check for it.
    @State private var copied: UUID?
    /// The dictation shown as its own page, or nil for the list.
    @State private var open: UUID?
    @State private var deletingPicked = false

    var body: some View {
        if let id = open, let entry = store.history.first(where: { $0.id == id }) {
            DictationPage(entry: entry) { open = nil }
        } else {
            list
        }
    }

    private var list: some View {
        let rows = filtered
        return VStack(alignment: .leading, spacing: 0) {
            SquarePageHeader(title: "history", count: counted(store.history.count, "dictation"),
                             status: KeepLimit.dictations.status(settings.historyLimit),
                             linkTitle: "history settings", onLink: showSettings)
            toolbar
            if rows.isEmpty {
                Text(store.history.isEmpty ? "nothing yet" : "no matches")
                    .font(Square.mono(12))
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .padding(.top, 40)
                    .padding(.leading, HistoryColumns.page + HistoryColumns.lead)
                Spacer(minLength: 0)
            } else {
                HistoryColumns.head.padding(.horizontal, HistoryColumns.page)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(HistoryTab.lines(rows)) { line in
                            switch line {
                            case .day(_, let day, let date, let total):
                                HistoryDayRow(day: day, date: date, total: total)
                            case .row(let entry):
                                HistoryRow(entry: entry, picked: picked(entry.id), picking: !selected.isEmpty, copied: copied == entry.id,
                                           open: { open = entry.id },
                                           copy: { Output.copyToClipboard(entry.displayText); copied = entry.id },
                                           delete: { store.delete(id: entry.id); selected.remove(entry.id) })
                            }
                        }
                    }
                    .padding(.horizontal, HistoryColumns.page)
                    .padding(.bottom, 20)
                }
            }
        }
        .onChange(of: store.history.map(\.id)) { _, ids in selected.formIntersection(ids) }
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
            Spacer(minLength: 0)
            if !selected.isEmpty {
                Button("delete \(selected.count)") { deletingPicked.toggle() }
                    .buttonStyle(SquareButtonStyle())
                    .squareConfirmDelete(isPresented: $deletingPicked, title: "delete \(counted(selected.count, "dictation"))?",
                                         detail: SquareDeleteConfirm.gone(selected.count)) {
                        store.delete(ids: selected)
                        selected = []
                    }
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, HistoryColumns.page)
        .padding(.bottom, 14)
    }

    // MARK: Filtering

    private var filtered: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let time = WhenFilter(when, from: from, to: to)
        return store.history.reversed().filter { e in
            if let app, HistoryTab.app(of: e) != app { return false }
            if !time.contains(e.timestamp) { return false }
            if !q.isEmpty, !e.displayText.lowercased().contains(q), !e.transcript.lowercased().contains(q) { return false }
            return true
        }
    }

    static func app(of entry: HistoryEntry) -> String { entry.appName?.lowercased() ?? "unknown" }

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

    enum Line: Identifiable {
        case day(id: Date, day: String, date: String, total: String)
        case row(HistoryEntry)

        var id: String {
            switch self {
            case .day(let id, _, _, _): "day-\(id.timeIntervalSinceReferenceDate)"
            case .row(let entry): entry.id.uuidString
            }
        }
    }

    /// The rows under a line for each day, newest first, the day saying how
    /// much it held.
    static func lines(_ rows: [HistoryEntry], calendar: Calendar = .current) -> [Line] {
        var out: [Line] = []
        var i = rows.startIndex
        while i < rows.endIndex {
            let day = calendar.startOfDay(for: rows[i].timestamp)
            var j = i
            while j < rows.endIndex, calendar.isDate(rows[j].timestamp, inSameDayAs: day) { j += 1 }
            let same = rows[i..<j]
            let words = same.reduce(0) { $0 + HistoryTab.words(in: $1) }
            let label = HistoryTab.dayLabel(day, calendar: calendar)
            out.append(.day(id: day, day: label.day, date: label.date,
                            total: "\(counted(same.count, "dictation")) · \(counted(words, "word"))"))
            out.append(contentsOf: same.map(Line.row))
            i = j
        }
        return out
    }

    static func words(in entry: HistoryEntry) -> Int {
        entry.displayText.split(whereSeparator: \.isWhitespace).count
    }

    /// "today" over "thursday 24 september"; an older day by its weekday,
    /// over its date.
    static func dayLabel(_ day: Date, calendar: Calendar = .current) -> (day: String, date: String) {
        let full = day.formatted(.dateTime.weekday(.wide).day().month(.wide)).lowercased()
        if calendar.isDateInToday(day) { return ("today", full) }
        if calendar.isDateInYesterday(day) { return ("yesterday", full) }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        let date = sameYear ? day.formatted(.dateTime.day().month(.wide)) : day.formatted(.dateTime.day().month(.wide).year())
        return (day.formatted(.dateTime.weekday(.wide)).lowercased(), date.lowercased())
    }

    private func picked(_ id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { _ in select(id) })
    }

    private func select(_ id: UUID) {
        // A SwiftUI button hands its action no event, so the modifier is read
        // from the keyboard as the click lands.
        selected = HistorySelection.clicked(id, extending: NSEvent.modifierFlags.contains(.shift),
                                            anchor: anchor, in: filtered.map(\.id), selected: selected)
        anchor = id
    }
}

/// History's columns: the select box, time, the dictation, its app and its
/// words, and a copy and a delete at the end. The head, the days and the rows
/// share them.
enum HistoryColumns {
    static let page: CGFloat = 20
    static let tick: CGFloat = 22
    static let time: CGFloat = 60
    static let app: CGFloat = 116
    static let words: CGFloat = 52
    static let action: CGFloat = 26
    static let gap: CGFloat = 16
    /// Between the select box and the row.
    static let edge: CGFloat = 4
    /// Between the words and the first action's box, whose own margin makes
    /// up the rest of a column's gap. The two actions sit box to box.
    static let actionLead: CGFloat = 8
    /// What the two actions take at the end of a row.
    static var actions: CGFloat { actionLead + action * 2 }
    /// The select box and the actions are centred on the first line of the
    /// row, where its words are: this far above the line's baseline.
    static let lineMiddle = Square.appKitMono(12).capHeight / 2
    /// How far the columns sit inside the row's own left edge.
    static let inset: CGFloat = 8
    /// Where the time column starts, from the list's edge.
    static var lead: CGFloat { tick + edge + inset }

    static var head: some View {
        HStack(spacing: edge) {
            Color.clear.frame(width: tick, height: 1)
            HStack(spacing: gap) {
                Text("time").frame(width: time, alignment: .leading)
                Text("dictation").frame(maxWidth: .infinity, alignment: .leading)
                Text("app").frame(width: app, alignment: .leading)
                Text("words").frame(width: words, alignment: .trailing)
            }
            .padding(.leading, inset)
            Color.clear.frame(width: actions, height: 1)
        }
        .font(Square.mono(11))
        .foregroundStyle(DesignTokens.Colors.ink3)
        .padding(.trailing, inset)
        .padding(.bottom, 8)
    }
}

/// A day in the list: an ink rule, the day under the time, its date under
/// the dictations, and how much it held under the app and words.
private struct HistoryDayRow: View {
    let day: String
    let date: String
    let total: String

    var body: some View {
        HStack(spacing: HistoryColumns.edge) {
            Color.clear.frame(width: HistoryColumns.tick, height: 1)
            HStack(alignment: .firstTextBaseline, spacing: HistoryColumns.gap) {
                // "yesterday" is wider than the time column; it runs into the gap.
                Text(day)
                    .font(Square.mono(12, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.ink)
                    .fixedSize()
                    .frame(width: HistoryColumns.time, alignment: .leading)
                Text(date)
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(total)
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: HistoryColumns.app + HistoryColumns.gap + HistoryColumns.words, alignment: .trailing)
            }
            .padding(.leading, HistoryColumns.inset)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Color.clear.frame(width: HistoryColumns.actions, height: 1)
        }
        .padding(.trailing, HistoryColumns.inset)
        .overlay(alignment: .top) { SquareRule(color: DesignTokens.Colors.ink) }
        .padding(.top, 6)
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
                .frame(width: HistoryColumns.tick)
                .opacity(hovering || picking || picked ? 1 : 0)
                .help(picked ? "deselect" : "select · shift-click for a range")
                .onFirstLine()
                .padding(.trailing, HistoryColumns.edge)
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: HistoryColumns.gap) {
                    Text(entry.timestamp.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                        .font(Square.mono(12))
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Colors.ink2)
                        .frame(width: HistoryColumns.time, alignment: .leading)
                    Text(entry.displayText)
                        .font(Square.sans(13.5))
                        .lineSpacing(2)
                        .lineLimit(2)
                        .foregroundStyle(DesignTokens.Colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(HistoryTab.app(of: entry)).lineLimit(1)
                        if entry.edited != nil { SquareTag(text: "edited") }
                    }
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .frame(width: HistoryColumns.app, alignment: .leading)
                    Text(HistoryTab.words(in: entry).formatted())
                        .font(Square.mono(12))
                        .monospacedDigit()
                        .foregroundStyle(DesignTokens.Colors.ink)
                        .frame(width: HistoryColumns.words, alignment: .trailing)
                }
                .padding(.leading, HistoryColumns.inset)
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
        .padding(.trailing, HistoryColumns.inset)
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
