import SwiftUI

struct InsightsTab: View {
    @State private var store = Store.shared
    @State private var meetingStore = MeetingStore.shared
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
    /// The where box's content at its own height, before the row sizes it.
    @State private var whereHeight: CGFloat = 0
    /// Calendar cell under the pointer, as its `YYYY-MM-DD` key.
    /// The streak cell whose day is shown; a click on the box outside the
    /// cells lets it go.
    @State private var selectedDay: String?
    /// The figures, kept across redraws that change neither the filters nor
    /// the data: a hover on the calendar, a resize.
    @State private var cache = FiguresCache()

    /// The meetings the filters leave.
    private var shownMeetings: [Meeting] {
        let time = WhenFilter(when, from: from, to: to)
        return meetingStore.meetings.filter { MeetingsTab.matches($0, place: place, people: people) && time.contains($0.started) }
    }

    /// The dictations the filters leave. Who and channels belong to meetings,
    /// so once either is set, what stays is what was dictated during them.
    private func shownHistory(during meetings: [Meeting]) -> [HistoryEntry] {
        let time = WhenFilter(when, from: from, to: to)
        let channel = place.map { p in meetingStore.meetings.contains { MeetingsTab.channel(of: $0) == p } } ?? false
        let during: Set<UUID>? = people.isEmpty && !channel ? nil : Set(meetings.flatMap { $0.dictations.map(\.historyId) })
        return store.history.filter { e in
            if let during {
                if !during.contains(e.id) { return false }
            } else if let place, HistoryTab.app(of: e) != place {
                return false
            }
            return time.contains(e.timestamp)
        }
    }

    private func stats(_ meetings: [Meeting]) -> InsightsStats {
        Insights.compute(shownHistory(during: meetings).map {
            InsightRow(timestamp: $0.timestamp, transcript: $0.transcript, postProcessed: $0.postProcessed,
                       postProcessRequested: $0.postProcessRequested, durationMs: $0.durationMs,
                       transcribeMs: $0.transcribeMs, postProcessMs: $0.postProcessMs,
                       dictionaryFixes: $0.dictionaryFixes, appId: $0.appId, appName: $0.appName, windowTitle: $0.windowTitle)
        }, meetings: meetings.filter { $0.isDone && $0.recordedHere }.map {
            InsightMeeting(started: $0.started, appId: $0.app?.bundleId, appName: $0.app?.name)
        })
    }

    private static let gaugeMax = 200.0
    /// Tonal ramp of ink, darkest for the largest share. Indexed by rank.
    private static let ramp: [Color] = [
        DesignTokens.Colors.ink, DesignTokens.Colors.inkA64, DesignTokens.Colors.inkA48, DesignTokens.Colors.inkA32,
        DesignTokens.Colors.inkA20, DesignTokens.Colors.inkA12, DesignTokens.Colors.inkA08, DesignTokens.Colors.inkA04,
    ]
    private static func tone(_ rank: Int) -> Color { ramp[min(rank, ramp.count - 1)] }

    var body: some View {
        let (s, m) = cache.figures(for: figuresKey) {
            let shown = shownMeetings
            return (stats(shown), MeetingInsights.compute(shown))
        }
        VStack(spacing: 0) {
            toolbar
            // Scrolls only when the window is too short for the page.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        statCard("words dictated", s.totalWords.formatted(), monthCaption(s))
                        wpmCard(s)
                        statCard("fixes", (s.dictionaryFixes + s.postProcessFixes).formatted(), fixCaption(s))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    // The where box sets the row's height, rounded up to whole app
                    // rows, so the last app shown has the same room below it as
                    // the first has above; the rest of the apps scroll.
                    let rowBox = appsBoxHeight(covering: whereHeight)
                    HStack(alignment: .top, spacing: 12) {
                        SettingsGroup(title: "where") {
                            categories(s)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { whereHeight = $0 }
                                .frame(height: rowBox, alignment: .top)
                        }
                        .frame(maxWidth: .infinity)
                        SettingsGroup(title: "apps · \(s.totalApps)") {
                            ScrollView { topApps(s) }
                                .scrollBounceBehavior(.basedOnSize)
                                .frame(height: rowBox)
                        }
                        .frame(width: 330)
                    }
                    SettingsGroup(title: s.currentStreak > 0 ? "\(s.currentStreak) day streak · longest \(s.longestStreak)" : "streak · longest \(s.longestStreak)") {
                        calendar(s)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        SettingsGroup(title: "length") { length(s) }
                        SettingsGroup(title: "speed") { speed(s) }
                    }
                    meetings(m)
                }
                .padding([.horizontal, .bottom], 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            SquareFilter(label: place ?? "where", active: place != nil, clear: { place = nil }, open: $whereOpen) {
                let items = MeetingsTab.placeItems(meetings: meetingStore.meetings, dictations: store.history, place: place)
                SquareMenuList(items: items.map(\.item), minWidth: 232) { i in
                    place = items[i].value
                    whereOpen = false
                }
            }
            SquareFilter(label: people.isEmpty ? "who" : people.sorted().joined(separator: ", "), active: !people.isEmpty,
                         clear: { people = [] }, open: $whoOpen) {
                WhoMenu(people: $people, counts: MeetingsTab.personCounts(in: meetingStore.meetings))
            }
            let time = WhenFilter(when, from: from, to: to)
            SquareFilter(label: time.label, active: time.narrows, clear: { when = .any; from = ""; to = "" }, open: $whenOpen) {
                SquareWhenPicker(when: $when, from: $from, to: $to)
            }
            Spacer(minLength: 0)
            if filtering {
                Button("clear", action: clearFilters).buttonStyle(SquareButtonStyle(kind: .quiet, small: true))
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var figuresKey: FiguresCache.Key {
        FiguresCache.Key(place: place, people: people, when: when, from: from, to: to,
                         today: Calendar.current.startOfDay(for: .now),
                         history: store.revision, meetings: meetingStore.revision)
    }

    private var filtering: Bool { place != nil || !people.isEmpty || WhenFilter(when, from: from, to: to).narrows }

    private func clearFilters() {
        place = nil
        people = []
        when = .any
        from = ""
        to = ""
    }

    /// What an empty box says: nothing has happened, or nothing the filters
    /// leave.
    private var empty: String { filtering ? "no matches" : "nothing yet" }

    /// Time in meetings, your share of the talk on calls, and how long one runs.
    private func meetings(_ m: MeetingStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("meetings").font(DesignTokens.Fonts.label.weight(.regular).monospaced()).foregroundStyle(DesignTokens.Colors.ink2)
            HStack(alignment: .top, spacing: 12) {
                statCard("in meetings", m.meetings == 0 ? "–" : InsightsTab.span(m.totalMs),
                         m.meetings == 0 ? empty : "\(counted(m.meetings, "meeting")) · \(InsightsTab.span(m.thisMonthMs)) this month")
                statCard("you talked", m.callTalkMs == 0 ? "–" : "\(Int((Double(m.yourTalkMs) / Double(m.callTalkMs) * 100).rounded()))%",
                         m.callTalkMs == 0 ? "no calls yet" : "of the talk on calls · \(InsightsTab.span(m.yourTalkMs))")
                statCard("typical meeting", m.medianMs.map { MeetingFolder.durationLabel(.milliseconds($0)) } ?? "–",
                         typicalCaption(m))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `longest 47m · most on slack`.
    private func typicalCaption(_ m: MeetingStats) -> String {
        guard let longest = m.longestMs else { return empty }
        let most = m.topApp.map { " · most on \($0.lowercased())" } ?? ""
        return "longest \(MeetingFolder.durationLabel(.milliseconds(longest)))" + most
    }

    private func monthCaption(_ s: InsightsStats) -> String {
        let delta: String
        if s.wordsPreviousMonth > 0 {
            let pct = Int((Double(s.wordsThisMonth - s.wordsPreviousMonth) / Double(s.wordsPreviousMonth) * 100).rounded())
            delta = (pct >= 0 ? "+" : "") + "\(pct)% this month"
        } else {
            delta = "\(s.wordsThisMonth.formatted()) this month"
        }
        return "\(delta) · \(counted(s.totalDictations, "dictation"))"
    }

    /// The fixes as a share of everything dictated, then the two kinds of fix
    /// they are made of.
    private func fixCaption(_ s: InsightsStats) -> String {
        let breakdown = "\(counted(s.dictionaryFixes, "word")) · \(counted(s.postProcessFixes, "clean-up"))"
        guard s.totalWords > 0 else { return breakdown }
        let share = Double(s.dictionaryFixes + s.postProcessFixes) / Double(s.totalWords) * 100
        return String(format: "%.1f%% of words · ", share) + breakdown
    }

    private static let percentileColumns: [(name: String, value: KeyPath<Percentiles, Int>)] = [
        ("p50", \.p50), ("p75", \.p75), ("p90", \.p90), ("p95", \.p95),
    ]
    private static let percentileColumnWidth: CGFloat = 56

    /// How long one dictation runs and how much it says, by percentile.
    private func length(_ s: InsightsStats) -> some View {
        VStack(spacing: 0) {
            percentileHeader
            percentileRow("speech", s.audioMs, InsightsTab.duration)
            RowRule()
            percentileRow("words", s.wordsPerDictation, { $0.formatted() })
        }
    }

    /// How long each half of the pipeline takes over one dictation, by
    /// percentile, so the slow tail shows next to the typical run.
    private func speed(_ s: InsightsStats) -> some View {
        VStack(spacing: 0) {
            percentileHeader
            percentileRow("parakeet", s.transcribeMs, InsightsTab.duration)
            RowRule()
            percentileRow("apple intelligence", s.cleanUpMs, InsightsTab.duration,
                          detail: s.cleanUpMs == nil ? "no clean-ups yet" : nil)
        }
    }

    private var percentileHeader: some View {
        HStack(spacing: 12) {
            Spacer()
            ForEach(InsightsTab.percentileColumns, id: \.name) { column in
                Text(column.name).font(.system(size: 10).monospaced()).foregroundStyle(DesignTokens.Colors.ink3)
                    .frame(width: InsightsTab.percentileColumnWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
    }

    private func percentileRow(_ label: String, _ value: Percentiles?, _ format: @escaping (Int) -> String, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12))
            Spacer()
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink3) }
            ForEach(InsightsTab.percentileColumns, id: \.name) { column in
                Text(value.map { format($0[keyPath: column.value]) } ?? "–")
                    .font(.system(size: 12).monospaced()).foregroundStyle(DesignTokens.Colors.ink2)
                    .frame(width: InsightsTab.percentileColumnWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Milliseconds under a second, seconds above it.
    private static func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    private func statCard(_ label: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11).monospaced()).foregroundStyle(DesignTokens.Colors.ink2)
            Text(value).font(.system(size: 26, weight: .medium, design: .monospaced))
            Text(caption).font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink2)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
    }

    /// `2.5× faster than typing · 4.2 h saved`. The saving is left off when
    /// speaking came out slower, since there is none.
    private func wpmCaption(_ s: InsightsStats) -> String {
        guard let wpm = s.wordsPerMinute, wpm > 0 else { return "not yet" }
        let faster = String(format: "%.1f× faster than typing", wpm / Insights.typingWPM)
        guard let saved = s.timeSavedMs, saved > 0 else { return faster }
        return "\(faster) · \(InsightsTab.span(saved)) saved"
    }

    /// Minutes under an hour, hours above it.
    private static func span(_ ms: Int) -> String {
        let minutes = Double(ms) / 60_000
        return minutes < 60 ? "\(Int(minutes.rounded())) min" : String(format: "%.1f h", minutes / 60)
    }

    private func wpmCard(_ s: InsightsStats) -> some View {
        let wpm = s.wordsPerMinute ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            Text("words per minute").font(.system(size: 11).monospaced()).foregroundStyle(DesignTokens.Colors.ink2)
            Text(wpm > 0 ? "\(Int(wpm.rounded()))" : "–").font(.system(size: 26, weight: .medium, design: .monospaced))
            Text(wpmCaption(s))
                .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink2)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(DesignTokens.Colors.inkA08).frame(height: 6)
                    Rectangle().fill(DesignTokens.Colors.ink).frame(width: geo.size.width * min(1, wpm / InsightsTab.gaugeMax), height: 6)
                    Rectangle().fill(DesignTokens.Colors.ink2).frame(width: 1.5, height: 12)
                        .offset(x: geo.size.width * (Insights.typingWPM / InsightsTab.gaugeMax), y: 0)
                }
            }
            .frame(height: 12).padding(.top, 8)
            HStack { Text("typing \(Int(Insights.typingWPM))"); Spacer(); Text("you \(Int(wpm.rounded()))") }.font(.system(size: 10).monospaced()).foregroundStyle(DesignTokens.Colors.ink3)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
    }

    private func categories(_ s: InsightsStats) -> some View {
        let total = max(1, s.categories.reduce(0) { $0 + $1.dictations })
        return VStack(alignment: .leading, spacing: 10) {
            if s.categories.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(DesignTokens.Colors.ink2)
            } else {
                GeometryReader { geo in
                    let shown = s.categories.filter { $0.dictations > 0 }
                    let usable = geo.size.width - 2 * CGFloat(max(0, shown.count - 1))
                    HStack(spacing: 2) {
                        ForEach(Array(s.categories.enumerated()), id: \.element.category) { i, c in
                            if c.dictations > 0 {
                                Rectangle().fill(InsightsTab.tone(i))
                                    .frame(width: usable * CGFloat(c.dictations) / CGFloat(total))
                            }
                        }
                    }
                    .frame(width: geo.size.width, alignment: .leading)
                    .clipped()
                }
                .frame(height: 10)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(Array(s.categories.enumerated()), id: \.element.category) { i, c in
                        HStack(spacing: 6) {
                            Rectangle().fill(InsightsTab.tone(i)).frame(width: 8, height: 8)
                            Text(c.category.displayName.lowercased()).font(.system(size: 12))
                            Spacer()
                            Text("\(Int((Double(c.dictations) / Double(total) * 100).rounded()))%").font(.system(size: 12).monospaced()).foregroundStyle(DesignTokens.Colors.ink2)
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    /// One app row, and the room above the first and below the last.
    private static let appRowHeight: CGFloat = 26
    private static let appsPadding: CGFloat = 8

    /// The least height of whole app rows, with their padding, that is at
    /// least `height`.
    private func appsBoxHeight(covering height: CGFloat) -> CGFloat {
        let rows = max(1, ((height - 2 * InsightsTab.appsPadding) / InsightsTab.appRowHeight).rounded(.up))
        return 2 * InsightsTab.appsPadding + rows * InsightsTab.appRowHeight
    }

    private func topApps(_ s: InsightsStats) -> some View {
        VStack(spacing: 0) {
            if s.topApps.isEmpty { Text(empty).font(.system(size: 12)).foregroundStyle(DesignTokens.Colors.ink2).frame(height: InsightsTab.appRowHeight) }
            ForEach(s.topApps, id: \.name) { a in
                HStack(spacing: 10) {
                    Text(a.name.lowercased()).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(a.words > 0 ? counted(a.words, "word") : "").font(.system(size: 12).monospaced()).foregroundStyle(DesignTokens.Colors.ink2)
                    Text(a.meetings > 0 ? counted(a.meetings, "meeting") : "").font(.system(size: 12).monospaced()).foregroundStyle(DesignTokens.Colors.ink2)
                        .frame(width: InsightsTab.meetingsColumnWidth, alignment: .trailing)
                }
                .frame(height: InsightsTab.appRowHeight)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, InsightsTab.appsPadding)
    }

    /// Fits `12 meetings` in the apps list.
    private static let meetingsColumnWidth: CGFloat = 84

    private static let calendarWeeks = 16

    /// One cell a day for the last sixteen weeks, shaded by how many
    /// dictations it saw; a day with only a meeting takes the lightest active
    /// shade. Clicking a cell puts its date and counts where the legend sits,
    /// so nothing moves.
    private func calendar(_ s: InsightsStats) -> some View {
        let byDate = Dictionary(uniqueKeysWithValues: s.activity.map { ($0.date, $0) })
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weeks = InsightsTab.calendarWeeks
        let start = cal.date(byAdding: .day, value: -(weeks * 7 - 1), to: today)!
        let maxCount = max(1, s.activity.map(\.dictations).max() ?? 1)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return HStack(alignment: .bottom, spacing: 12) {
            HStack(spacing: 3) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let date = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                            let key = f.string(from: date)
                            let n = byDate[key]?.dictations ?? 0
                            let met = (byDate[key]?.meetings ?? 0) > 0
                            Rectangle()
                                .fill(DesignTokens.Colors.ink.opacity(n == 0 ? (met ? 0.3 : 0.08) : 0.3 + 0.7 * Double(n) / Double(maxCount)))
                                .frame(width: 11, height: 11)
                                .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: selectedDay == key ? 1 : 0))
                                .onTapGesture { selectedDay = selectedDay == key ? nil : key }
                        }
                    }
                }
            }
            Spacer()
            if let shown = selectedDay {
                Text(InsightsTab.dayCaption(shown, byDate[shown]))
                    .font(.system(size: 10).monospaced()).foregroundStyle(DesignTokens.Colors.ink3)
            } else {
                HStack(spacing: 4) {
                    Text("less").font(.system(size: 10).monospaced()).foregroundStyle(DesignTokens.Colors.ink3)
                    ForEach([0.08, 0.3, 0.55, 0.8, 1.0], id: \.self) { o in Rectangle().fill(DesignTokens.Colors.ink.opacity(o)).frame(width: 9, height: 9) }
                    Text("more").font(.system(size: 10).monospaced()).foregroundStyle(DesignTokens.Colors.ink3)
                }
            }
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture { selectedDay = nil }
    }

    /// `thu 12 sep · 14 dictations · 1,203 words · 2 meetings`, or `thu 12 sep · nothing`.
    static func dayCaption(_ key: String, _ day: DayActivity?) -> String {
        let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"
        let shown = DateFormatter(); shown.dateFormat = "EEE d MMM"
        let date = iso.date(from: key).map { shown.string(from: $0).lowercased() } ?? key
        guard let day, day.dictations > 0 || day.meetings > 0 else { return "\(date) · nothing" }
        var parts = [date]
        if day.dictations > 0 { parts += [counted(day.dictations, "dictation"), counted(day.words, "word")] }
        if day.meetings > 0 { parts.append(counted(day.meetings, "meeting")) }
        return parts.joined(separator: " · ")
    }
}

/// The insights page's figures and what they were worked out from.
@MainActor private final class FiguresCache {
    struct Key: Equatable {
        let place: String?
        let people: Set<String>
        let when: SquareWhen
        let from: String
        let to: String
        /// The when presets move on at midnight.
        let today: Date
        let history: Int
        let meetings: Int
    }

    private var key: Key?
    private var figures: (InsightsStats, MeetingStats)?

    func figures(for key: Key, compute: () -> (InsightsStats, MeetingStats)) -> (InsightsStats, MeetingStats) {
        if key == self.key, let figures { return figures }
        let fresh = compute()
        self.key = key
        figures = fresh
        return fresh
    }
}
