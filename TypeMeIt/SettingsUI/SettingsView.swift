import SwiftUI

enum SettingsTab: String, CaseIterable {
    // The order the sidebar lists them in.
    case insights, history, meetings, dictionary, settings

    /// The tabs this build shows. Insights are built on window titles, which
    /// the sandbox cannot read, so a sandboxed build has no insights page.
    static var available: [SettingsTab] {
        allCases.filter { $0 != .insights || Sandbox.readsOtherApps }
    }

    var icon: String {
        switch self {
        case .insights: "akar-statistic-up"
        case .history: "akar-history"
        case .meetings: "akar-people-group"
        case .dictionary: "akar-text-align-left"
        case .settings: "akar-gear"
        }
    }
}

/// The window: the sidebar, and the chosen page under its title. A page's
/// title carries its count and state, and a link to its settings.
struct SettingsView: View {
    @State private var tab = SettingsTab.available[0]
    /// The settings page's open groups, kept while other pages are shown.
    @State private var openSections: Set<SettingsSection> = []
    /// The group a page's link asked for, for the settings page to scroll to.
    @State private var reveal: SettingsSection?
    @State private var appState = AppState.shared
    @State private var settings = Settings.shared
    @State private var store = Store.shared
    @State private var meetings = MeetingStore.shared
    @State private var coordinator = MeetingCoordinator.shared
    /// `.key` while this window is in front.
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var scheme

    /// How far under the title bar the sidebar's mark sits, clear of the
    /// window's buttons.
    private static let markDrop: CGFloat = 27

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                header
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(DesignTokens.Colors.paper)
        }
        .tint(DesignTokens.Colors.ink)
        .frame(minWidth: 900, minHeight: 640)
        .onAppear { takeRequestedTab(); Updates.shared.checkNow(); appState.visibleTab = tab }
        .onDisappear { appState.visibleTab = nil }
        .onChange(of: appState.settingsTab) { _, _ in takeRequestedTab() }
        .onChange(of: tab) { _, now in appState.visibleTab = now }
        .onChange(of: activeState) { _, state in if state == .key { Updates.shared.checkNow() } }
    }

    private var sidebar: some View {
        // Ticks only while a meeting records, for the clock in the cloud's tooltip.
        TimelineView(.animation(minimumInterval: 1, paused: coordinator.recording == nil)) { context in
            SquareSidebar(
                items: SettingsTab.available.map { SquareSidebar.Item(page: $0, title: $0.rawValue, icon: $0.icon) },
                selection: $tab,
                recording: recordingLabel(at: context.date),
                level: coordinator.levels.mic,
                tint: cloudTint,
                record: { coordinator.recordRoom() },
                stop: { coordinator.stopMeeting() }
            )
        }
        .safeAreaPadding(.top, SettingsView.markDrop)
    }

    /// History and meetings draw their own, which a dictation's or a
    /// meeting's page replaces.
    @ViewBuilder private var header: some View {
        switch tab {
        case .history, .meetings:
            EmptyView()
        case .dictionary:
            SquarePageHeader(title: tab.rawValue, count: counted(settings.customWords.count, "word"), status: learnedStatus)
        case .insights, .settings:
            SquarePageHeader(title: tab.rawValue)
        }
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .insights: InsightsTab()
        case .history: HistoryTab(showSettings: { open(.onThisMac) })
        case .meetings: MeetingsTab(showSettings: { open(.meetings) })
        case .dictionary: DictionaryTab()
        case .settings: OnePageSettings(open: $openSections, reveal: $reveal)
        }
    }

    /// Where the meeting is and how long it has run, as "slack · 12:04".
    private func recordingLabel(at now: Date) -> String? {
        guard let live = coordinator.recording else { return nil }
        let place = live.kind == .room ? "room" : meetings.meeting(live.id)?.app?.name.lowercased() ?? "call"
        let elapsed = Duration.seconds(max(0, now.timeIntervalSince(live.started)))
        let hour = Duration.seconds(60 * 60)
        return "\(place) · \(elapsed.formatted(.time(pattern: elapsed < hour ? .minuteSecond : .hourMinuteSecond)))"
    }

    /// The recording cloud in the colour the user chose, as the palette
    /// draws it.
    private var cloudTint: Color {
        SquareCloudPalette.tint(settings.cloudChoice, scheme: scheme)
    }

    private var learnedStatus: String? {
        let learned = settings.customWords.filter { store.learnedRecord(for: $0) != nil }.count
        return learned > 0 ? "\(learned) learned from corrections" : nil
    }

    /// Shows the settings page with the group open and in view.
    private func open(_ group: SettingsSection) {
        openSections.insert(group)
        reveal = group
        tab = .settings
    }

    private func takeRequestedTab() {
        guard let requested = appState.settingsTab else { return }
        tab = requested
        appState.settingsTab = nil
    }
}
