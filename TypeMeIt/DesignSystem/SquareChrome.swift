import SwiftUI

/// The sidebar: the cloud's mark, the pages as a flush list with the chosen
/// one inverted across the column's full width, and at the foot "record the
/// room". While a meeting records, the foot is the cloud moving with the
/// microphone and where and how long, and a click stops it.
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
    /// "record the room" at the foot; off where the build has no meetings.
    var showsFoot = true

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
            if showsFoot { foot }
        }
        .frame(width: SquareSidebarLayout.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.Colors.paper)
        .overlay(alignment: .trailing) { Rectangle().fill(DesignTokens.Colors.rule).frame(width: DesignTokens.hairline).ignoresSafeArea() }
    }

    private var foot: some View {
        SquareSidebarFoot(recording: recording, level: level, tint: tint, record: record, stop: stop)
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
    /// Room above and below the foot's label inside its band, so a loud
    /// cloud billowing out of its icon's place is never cut by the window's edge.
    static let footDrop: CGFloat = 12
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
                SidebarIcon(name: icon, hovering: pose.hot(hovering))
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

/// The sidebar's foot, a band across the column's whole bottom: at rest,
/// "record the room" inverted with the cloud in the icon's place; while a
/// meeting records, the cloud moving with the microphone and where and how
/// long, which reads "stop" under the pointer.
private struct SquareSidebarFoot: View {
    let recording: String?
    let level: Float
    let tint: Color
    let record: () -> Void
    let stop: () -> Void
    @Environment(\.squarePose) private var pose
    @State private var hovering = false

    var body: some View {
        let hot = pose.hot(hovering)
        Button(action: recording == nil ? record : stop) {
            HStack(spacing: 10) {
                if let recording {
                    // A resting puff shows in about half the cell it is drawn for.
                    PuffView(level: level, tint: tint)
                        .frame(width: PuffView.drawnSide(filling: SquareSidebarLayout.icon * 2),
                               height: PuffView.drawnSide(filling: SquareSidebarLayout.icon * 2))
                        .frame(width: SquareSidebarLayout.icon, height: SquareSidebarLayout.icon)
                    Text(hot ? "stop" : recording)
                } else {
                    StormCloud(striking: hot)
                    Text("record the room")
                }
            }
            .font(Square.mono(14, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(recording == nil ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink)
            .padding(.horizontal, SquareSidebarLayout.itemInset)
            .frame(maxWidth: .infinity, minHeight: 34 + 2 * SquareSidebarLayout.footDrop, alignment: .leading)
            .background(
                // Idle and recording fill the same band, down to the window's edge.
                Rectangle().fill(recording == nil ? DesignTokens.Colors.slab : hot ? DesignTokens.Colors.inkA04 : .clear).ignoresSafeArea()
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.18), value: hot)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(recording.map { "stop recording · \($0)" } ?? "")
        .accessibilityLabel(recording == nil ? "record the room" : "stop recording")
    }
}

/// A sidebar icon with its hover pose: each icon makes one small gesture
/// that fits what it draws, and the pose holds while hovered and eases
/// back on leaving. An icon whose parts move is drawn from one asset per
/// part, stacked on the same 24-unit grid.
private struct SidebarIcon: View {
    let name: String
    let hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Every icon's hover, in and out: one length, one curve.
    static let duration = 0.3
    static let spring = Animation.spring(duration: duration, bounce: 0.25)

    /// One drawn part and where it goes under the pointer, in the icon's
    /// 24-unit grid.
    private struct Part {
        var asset: String
        var x: CGFloat = 0
        var y: CGFloat = 0
        var degrees: Double = 0
        var anchor: UnitPoint = .center
    }

    private var parts: [Part] {
        switch name {
        case "akar-statistic-up":
            [Part(asset: "akar-statistic-up-base"), Part(asset: "akar-statistic-up-arrow", x: 1.5, y: -1.5)]
        case "akar-people-group":
            [Part(asset: "akar-people-group-centre"), Part(asset: "akar-people-group-left", x: 1.5), Part(asset: "akar-people-group-right", x: -1.5)]
        case "akar-text-align-left":
            [Part(asset: "akar-text-align-left-top", y: 1), Part(asset: "akar-text-align-left-middle"), Part(asset: "akar-text-align-left-bottom", y: -1)]
        case "akar-gear": [Part(asset: name, degrees: 90)]
        default: [Part(asset: name, y: -1.5)]
        }
    }

    var body: some View {
        if name == "akar-chat-dots" { ChatDots(talking: hovering && !reduceMotion) } else { parted }
    }

    private var parted: some View {
        let hot = hovering && !reduceMotion
        let unit = SquareSidebarLayout.icon / 24
        return ZStack {
            ForEach(parts, id: \.asset) { part in
                SquareIcon(part.asset, size: SquareSidebarLayout.icon)
                    .rotationEffect(.degrees(hot ? part.degrees : 0), anchor: part.anchor)
                    .offset(x: hot ? part.x * unit : 0, y: hot ? part.y * unit : 0)
            }
        }
        .frame(width: SquareSidebarLayout.icon, height: SquareSidebarLayout.icon)
        .animation(SidebarIcon.spring, value: hot)
    }
}

/// The speech bubble, its three dots rising and settling in turn once as
/// the pointer arrives, in the same time as the other icons' hovers.
private struct ChatDots: View {
    let talking: Bool
    @State private var lifted = [false, false, false]

    var body: some View {
        ZStack {
            SquareIcon("akar-chat-bubble", size: SquareSidebarLayout.icon)
            ForEach(0..<3, id: \.self) { i in
                SquareIcon("akar-chat-dot-\(i + 1)", size: SquareSidebarLayout.icon)
                    .offset(y: lifted[i] ? -1.2 : 0)
            }
        }
        .frame(width: SquareSidebarLayout.icon, height: SquareSidebarLayout.icon)
        .onChange(of: talking) { _, now in
            guard now else { return }
            // Three dots, each up and down in a third of the hover's time,
            // a sixth apart, so the wave ends with the others.
            let step = SidebarIcon.duration / 3
            for i in 0..<3 {
                withAnimation(.easeOut(duration: step / 2).delay(Double(i) * step / 2)) { lifted[i] = true }
                withAnimation(.easeOut(duration: step).delay(Double(i) * step / 2 + step / 2)) { lifted[i] = false }
            }
        }
    }
}

/// The cloud in the slab's ink, drawn as the recording puff is at silence,
/// so it is the same size before and while a meeting records.
/// The pointer arriving strikes lightning through it, as a click on the
/// website's puff does.
private struct StormCloud: View {
    let striking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var strike: Date?

    var body: some View {
        let side = PuffView.drawnSide(filling: SquareSidebarLayout.icon * 2)
        PuffView(level: 0, tint: DesignTokens.Colors.onSlab, frozenTime: reduceMotion ? 0 : nil,
                 frameInterval: 1.0 / 30, strike: strike)
            .frame(width: side, height: side)
            .frame(width: SquareSidebarLayout.icon, height: SquareSidebarLayout.icon)
            .onChange(of: striking) { _, now in
                if now, !reduceMotion { strike = Date() }
            }
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
            .init(page: .history, title: "dictations", icon: "akar-chat-dots"),
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
                SquarePageHeader(title: "dictations", count: "563 dictations", status: "keeps everything", linkTitle: "history settings")
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
