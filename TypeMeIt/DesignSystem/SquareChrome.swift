import SwiftUI

/// The sidebar: the cloud's mark, the pages as a flush list with the chosen
/// one inverted across the column's full width, and at the foot the cloud
/// alone. At rest a click records the room; while a meeting records the
/// cloud moves with the microphone and a click stops it.
struct SquareSidebar<Page: Hashable>: View {
    struct Item {
        let page: Page
        let title: String
        let icon: String
    }

    let items: [Item]
    @Binding var selection: Page
    /// Where and for how long, as "slack · 12:04", while a meeting records.
    var recording: String?
    /// The microphone's level while a meeting records, which the cloud moves with.
    var level: Float = 0
    /// The cloud's colour.
    var tint = Color(nsColor: CloudColor.sky.color)
    var record: () -> Void = {}
    var stop: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Drawn as a template so it follows the appearance.
            Image(nsImage: MenuBarIconRenderer.mark(side: 32))
                .renderingMode(.template)
                .resizable()
                .foregroundStyle(DesignTokens.Colors.ink)
                .frame(width: 32, height: 32)
                .padding(.leading, SquareSidebarLayout.markInset)
                .padding(.bottom, 29)
            ForEach(items.indices, id: \.self) { i in
                SquareSidebarItem(title: items[i].title, icon: items[i].icon, selected: items[i].page == selection) {
                    selection = items[i].page
                }
            }
            Spacer(minLength: 0)
            foot
        }
        .frame(width: SquareSidebarLayout.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Colors.paper)
        .overlay(alignment: .trailing) { Rectangle().fill(DesignTokens.Colors.rule).frame(width: DesignTokens.hairline) }
    }

    private var foot: some View {
        let label = recording.map { "stop recording · \($0)" } ?? "record the room"
        return Button(action: recording == nil ? record : stop) {
            PuffView(level: recording == nil ? 0 : level, tint: tint)
                .frame(width: PuffView.drawnSide(filling: SquareSidebarLayout.cloud * 2),
                       height: PuffView.drawnSide(filling: SquareSidebarLayout.cloud * 2))
                .frame(width: SquareSidebarLayout.cloud, height: SquareSidebarLayout.cloud)
        }
        .buttonStyle(SquareIconButtonStyle(side: SquareSidebarLayout.cloud + 2 * SquareSidebarLayout.cloudWash))
        .help(label)
        .accessibilityLabel(label)
        .padding(.leading, SquareSidebarLayout.markInset - SquareSidebarLayout.cloudWash)
        .padding(.bottom, SquareSidebarLayout.cloudWash * 3)
    }
}

enum SquareSidebarLayout {
    static let width: CGFloat = 200
    static let itemInset: CGFloat = 16
    /// The mark's outline starts further inside its 32 pt box than an icon's
    /// stroke does inside its 16 pt one, so the mark sits that much further
    /// left for the two to line up.
    static let markInset: CGFloat = itemInset - 3
    static let icon: CGFloat = 16
    /// The cloud at the foot, the mark's size, lined up under it. A resting
    /// puff shows in about half the cell it is drawn for.
    static let cloud: CGFloat = 32
    /// How far the pointer's grey square reaches round the cloud.
    static let cloudWash: CGFloat = 4
}

private struct SquareSidebarItem: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.squarePose) private var pose
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SquareIcon(icon, size: SquareSidebarLayout.icon)
                Text(title).font(Square.mono(14, weight: .medium))
            }
            .foregroundStyle(selected ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink2)
            .padding(.horizontal, SquareSidebarLayout.itemInset)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(Rectangle().fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: Color {
        if selected { return DesignTokens.Colors.slab }
        return pose.hot(hovering) ? DesignTokens.Colors.inkA04 : .clear
    }
}

/// A page's title over a hairline, and on its right the page's count in ink,
/// its state, and a link to its settings. `big` is the pages' 40 pt title;
/// otherwise 20 pt, for a page inside a page.
struct SquarePageHeader: View {
    let title: String
    var count: String?
    var status: String?
    var linkTitle: String?
    var onLink: () -> Void = {}
    var big = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(big ? DesignTokens.Fonts.display2 : Square.mono(20, weight: .medium))
                .tracking(big ? DesignTokens.Tracking.display2 : 0)
                .foregroundStyle(DesignTokens.Colors.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                if let count { Text(count).foregroundStyle(DesignTokens.Colors.ink).monospacedDigit() }
                if let status { Text(" · \(status)").foregroundStyle(DesignTokens.Colors.ink3) }
                if let linkTitle {
                    Text(" · ").foregroundStyle(DesignTokens.Colors.ink3)
                    SquareLink(title: linkTitle, color: DesignTokens.Colors.ink2, action: onLink)
                }
            }
            .font(Square.mono(11))
            .lineLimit(1)
            // The status says what the page holds; the title gives way first.
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.top, big ? 18 : 14)
        .padding(.bottom, big ? 16 : 14)
        .overlay(alignment: .bottom) { SquareRule() }
    }
}

/// A link that does something in the app: mono, underlined in ink-a32, the
/// underline going to full strength under the pointer.
struct SquareLink: View {
    let title: String
    var size: CGFloat = 11
    var color = DesignTokens.Colors.ink
    let action: () -> Void
    @Environment(\.squarePose) private var pose
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Square.mono(size))
                .foregroundStyle(color)
                .underline(true, color: pose.hot(hovering) ? color : DesignTokens.Colors.inkA32)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

#if DEBUG
private enum SpecimenPage: Hashable { case history, meetings, dictionary, settings }

struct SquareSidebarSpecimen: View {
    @State private var page = SpecimenPage.history
    @State private var recording: String?

    private var specimenPages: [SquareSidebar<SpecimenPage>.Item] {
        [
            .init(page: .history, title: "history", icon: "akar-history"),
            .init(page: .meetings, title: "meetings", icon: "akar-people-group"),
            .init(page: .dictionary, title: "dictionary", icon: "akar-text-align-left"),
            .init(page: .settings, title: "settings", icon: "akar-gear"),
        ]
    }

    var body: some View {
        SquareSpecimen {
            HStack(alignment: .top, spacing: 24) {
                SquareSidebar(items: specimenPages, selection: $page, recording: recording,
                              record: { recording = "room · 00:00" }, stop: { recording = nil })
                SquareSidebar(items: specimenPages, selection: .constant(.meetings), recording: "slack · 12:04", level: 0.6)
            }
            .frame(height: 400)
        }
    }
}

struct SquarePageHeaderSpecimen: View {
    var body: some View {
        SquareSpecimen {
            VStack(alignment: .leading, spacing: 24) {
                SquarePageHeader(title: "history", count: "563 dictations", status: "keeps everything", linkTitle: "history settings")
                SquarePageHeader(title: "meetings", count: "8 meetings", status: "asks when a call starts · 41.4 mb", linkTitle: "meeting settings")
                SquarePageHeader(title: "settings")
                SquarePageHeader(title: "pricing page review", big: false)
                HStack(spacing: 16) {
                    SquareLink(title: "connect an assistant") {}
                    SquareLink(title: "under the pointer") {}.environment(\.squarePose, .hover)
                }
            }
            .frame(width: 820)
        }
    }
}

#Preview("sidebar") { SquareSidebarSpecimen() }
#Preview("page header") { SquarePageHeaderSpecimen() }
#endif
