import SwiftUI

/// Hooks to run on a meeting as a run sheet: each one numbered, ticked when
/// it will run, and one button that runs the ticked ones. On the slab it is
/// the meeting pill grown open, its message on top; on paper it is the
/// meeting page's menu. "all" over the list ticks every hook shown, or
/// unticks them once all are. Past `visibleRows` the list scrolls and a find
/// line filters it; return ticks the first match.
struct SquareHookTray: View {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let name: String
        var picked: Bool
        /// Ink-3 at the line's end, such as "off".
        var note: String?
    }

    let items: [Item]
    /// The pill's message over the list; nil on paper, which has no head.
    var title: String?
    var onSlab = true
    var toggle: (UUID) -> Void
    /// Ticks (true) or unticks the hooks given.
    var setAll: ([UUID], Bool) -> Void
    var run: () -> Void
    var show: (() -> Void)?
    var close: (() -> Void)?
    @State private var find = ""

    static let width: CGFloat = 420
    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 7
    /// The line number's column, so "all" lines up with the names.
    fileprivate static let numberWidth: CGFloat = 16

    private var fg: Color { onSlab ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink }
    private var bg: Color { onSlab ? DesignTokens.Colors.slab : DesignTokens.Colors.paper }
    private var picked: Int { items.filter(\.picked).count }
    private var shown: [Item] { items.filter { find.isEmpty || $0.name.localizedCaseInsensitiveContains(find) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { head(title) }
            if items.count > SquareHookTray.visibleRows { findLine }
            list
            foot
        }
        .frame(width: SquareHookTray.width)
        .background(bg)
        .overlay { if !onSlab { Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline) } }
        .squareLift()
        .environment(\.squareOnSlab, onSlab)
    }

    private func head(_ title: String) -> some View {
        HStack(spacing: 12) {
            SquareIcon("akar-people-group", size: 14).foregroundStyle(fg)
            Text(title).font(Square.mono(13)).foregroundStyle(fg).lineLimit(1).centredLetters(title, size: 13)
            Spacer()
            if let show {
                Button(action: show) { SquareIcon("akar-arrow-right", size: 13) }
                    .buttonStyle(SquareIconButtonStyle(bordered: true))
                    .help("show meeting")
                    .accessibilityLabel("show meeting")
            }
            if let close {
                Button(action: close) { SquareIcon("akar-cross", size: 12) }
                    .buttonStyle(SquareIconButtonStyle())
                    .help("dismiss")
                    .accessibilityLabel("dismiss")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 48)
        .overlay(alignment: .bottom) { rule }
    }

    private var findLine: some View {
        HStack(spacing: 8) {
            SquareIcon("akar-search", size: 12).foregroundStyle(fg.opacity(0.6))
            TextField("find", text: $find, prompt: Text("find").foregroundStyle(fg.opacity(0.45)))
                .textFieldStyle(.plain)
                .font(Square.mono(12))
                .foregroundStyle(fg)
                .onSubmit {
                    guard !find.isEmpty, let first = shown.first else { return }
                    toggle(first.id)
                }
            let count = find.isEmpty ? "\(items.count)" : "\(shown.count) of \(items.count)"
            Text(count).font(Square.mono(11)).foregroundStyle(fg.opacity(0.5)).centredLetters(count, size: 11)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .overlay(alignment: .bottom) { rule }
    }

    @ViewBuilder private var list: some View {
        let rows = shown
        let lines = VStack(spacing: 0) {
            if rows.count > 1 { allLine(rows) }
            ForEach(Array(rows.enumerated()), id: \.element.id) { position, item in
                SquareHookTrayRow(number: position + 1, item: item, fg: fg, bg: bg, hot: position == 0 && !find.isEmpty) { toggle(item.id) }
            }
        }
        .padding(.vertical, 6)
        if rows.count > SquareHookTray.visibleRows {
            ScrollView { lines }
                .scrollIndicators(.never)
                .frame(height: CGFloat(SquareHookTray.visibleRows) * SquareHookTray.rowHeight + 12)
        } else {
            lines
        }
    }

    /// Its box is ticked when every hook shown is, dashed when some are.
    private func allLine(_ rows: [Item]) -> some View {
        let ticked = rows.filter(\.picked).count
        let every = ticked == rows.count
        return Button { setAll(rows.map(\.id), !every) } label: {
            HStack(spacing: 12) {
                Text("").frame(width: SquareHookTray.numberWidth)
                Rectangle()
                    .fill(every ? fg : .clear)
                    .overlay(Rectangle().strokeBorder(fg.opacity(ticked > 0 ? 1 : 0.4), lineWidth: DesignTokens.hairline))
                    .overlay {
                        if every {
                            SquareIcon("akar-check", size: 8).foregroundStyle(bg)
                        } else if ticked > 0 {
                            Rectangle().fill(fg).frame(width: 6, height: 1.5)
                        }
                    }
                    .frame(width: 12, height: 12)
                Text("all").font(Square.mono(13)).foregroundStyle(fg).centredLetters("all", size: 13)
                Spacer()
                let count = "\(ticked) of \(rows.count)"
                Text(count).font(Square.mono(11)).foregroundStyle(fg.opacity(0.5)).centredLetters(count, size: 11)
            }
            .padding(.horizontal, 14)
            .frame(height: SquareHookTray.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { rule.padding(.horizontal, 14) }
        .padding(.bottom, 4)
        .accessibilityLabel(every ? "untick all" : "tick all")
    }

    private var foot: some View {
        HStack {
            Spacer()
            Button(action: run) { SquareRunLabel(count: picked, named: true) }
                .buttonStyle(SquareButtonStyle(kind: .primary))
                .disabled(picked == 0)
                .help("run \(counted(picked, "hook"))")
                .accessibilityLabel("run \(counted(picked, "hook"))")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .overlay(alignment: .top) { rule }
    }

    private var rule: some View { Rectangle().fill(fg.opacity(0.18)).frame(height: DesignTokens.hairline) }
}

/// One hook in the tray: its number, its tick, its name and its note; a
/// click ticks it.
private struct SquareHookTrayRow: View {
    let number: Int
    let item: SquareHookTray.Item
    let fg: Color
    let bg: Color
    let hot: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                SquareRunNumber(number: number, colour: fg.opacity(0.45)).frame(width: SquareHookTray.numberWidth, alignment: .leading)
                Rectangle()
                    .fill(item.picked ? fg : .clear)
                    .overlay(Rectangle().strokeBorder(fg.opacity(item.picked ? 1 : 0.4), lineWidth: DesignTokens.hairline))
                    .overlay { if item.picked { SquareIcon("akar-check", size: 8).foregroundStyle(bg) } }
                    .frame(width: 12, height: 12)
                Text(item.name).font(Square.mono(13)).foregroundStyle(fg.opacity(item.picked ? 1 : 0.6))
                    .lineLimit(1).centredLetters(item.name, size: 13)
                Spacer()
                if let note = item.note {
                    Text(note).font(Square.mono(11)).foregroundStyle(fg.opacity(0.5)).centredLetters(note, size: 11)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(hot || hovering ? fg.opacity(0.1) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityValue(item.picked ? "ticked" : "not ticked")
    }
}

/// A run sheet's line number, two digits in mono.
struct SquareRunNumber: View {
    let number: Int
    var colour = DesignTokens.Colors.ink3

    var body: some View {
        let text = String(format: "%02d", number)
        Text(text).font(Square.mono(11)).foregroundStyle(colour).monospacedDigit().centredLetters(text, size: 11)
    }
}

/// Run as the play mark and how many hooks it starts, as "4 hooks" where
/// the label has room. The button lifts its label for lowercase; a bare
/// count centres on the cap height, so it goes back down by the difference.
struct SquareRunLabel: View {
    let count: Int
    var size: CGFloat = Square.controlSize
    /// Names the hooks after the count.
    var named = false

    var body: some View {
        HStack(spacing: 7) {
            SquareIcon("akar-play", size: 10)
            if named {
                Text(counted(count, "hook"))
            } else {
                Text("\(count)").monospacedDigit()
                    .offset(y: Square.drop(shortLetters: true, size: size) - Square.drop(shortLetters: false, size: size))
            }
        }
    }
}

/// "▷ n" with a chevron beside it: the button runs the hooks switched on,
/// the chevron opens the tray to pick.
struct SquareRunSplitButton: View {
    let count: Int
    var small = false
    var open = false
    var named = false
    let run: () -> Void
    let pick: () -> Void

    var body: some View {
        HStack(spacing: -DesignTokens.hairline) {
            Button(action: run) { SquareRunLabel(count: count, size: small ? 11 : Square.controlSize, named: named) }
                .buttonStyle(SquareButtonStyle(small: small))
                .disabled(count == 0)
                .help("run \(counted(count, "hook"))")
                .accessibilityLabel("run \(counted(count, "hook"))")
            Button(action: pick) { SquareIcon("akar-chevron-down", size: small ? 9 : 10).rotationEffect(.degrees(open ? 180 : 0)) }
                .buttonStyle(SquareButtonStyle(small: small))
                .help("pick")
                .accessibilityLabel("pick hooks")
        }
        .fixedSize()
    }
}
