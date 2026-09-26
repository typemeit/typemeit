import SwiftUI

/// The square choice: options side by side in one ink outline, split by
/// ink-a20 hairlines, the chosen one inverted to the slab. The pointer
/// washes the others.
struct SquareChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    var label: (Value) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { i, option in
                if i > 0 { Rectangle().fill(DesignTokens.Colors.inkA20).frame(width: DesignTokens.hairline) }
                SquareSegment(text: label(option), chosen: option == selection) { selection = option }
            }
        }
        .padding(DesignTokens.hairline)
        .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
        .fixedSize()
    }
}

extension SquareChoice where Value == String {
    init(selection: Binding<String>, options: [String]) {
        self.init(selection: selection, options: options) { $0 }
    }
}

private struct SquareSegment: View {
    let text: String
    let chosen: Bool
    let choose: () -> Void
    @Environment(\.squarePose) private var pose
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            Text(text)
                .font(Square.mono(Square.controlSize))
                .centredLetters(text)
                .foregroundStyle(chosen ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink2)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Rectangle().fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var fill: Color {
        if chosen { return DesignTokens.Colors.slab }
        return pose.hot(hovering) ? DesignTokens.Colors.inkA04 : .clear
    }
}

/// A square popup: the value and a chevron on the control rule. Under the
/// pointer its edge goes to ink and casts a button's hard shadow; while open
/// the edge stays ink. A click opens its options on a panel under it, right
/// edges lined up.
struct SquareMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    var label: (Value) -> String
    var minWidth: CGFloat = 190
    @State private var open = false
    @State private var hovering = false
    @Environment(\.squarePose) private var pose

    var body: some View {
        Button { open.toggle() } label: {
            let text = label(selection)
            HStack(spacing: 10) {
                Text(text).centredLetters(text)
                SquareIcon("akar-chevron-down", size: 10)
            }
            .font(Square.mono(Square.controlSize))
            .foregroundStyle(DesignTokens.Colors.ink)
            .padding(.leading, 8)
            .padding(.trailing, 7)
            .frame(height: 24)
            .overlay(Rectangle().strokeBorder(open || pose.hot(hovering) ? DesignTokens.Colors.ink : DesignTokens.Colors.ruleControl,
                                              lineWidth: DesignTokens.hairline))
            .squarePress(hot: !open && pose.hot(hovering), down: false, shadow: DesignTokens.Colors.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .squarePopover(isPresented: $open) {
            SquareMenuList(items: options.map { SquareMenuList.Item(label: label($0), checked: $0 == selection) }, minWidth: minWidth) { i in
                selection = options[i]
                open = false
            }
        }
    }
}

extension SquareMenu where Value == String {
    init(selection: Binding<String>, options: [String], minWidth: CGFloat = 190) {
        self.init(selection: selection, options: options, label: { $0 }, minWidth: minWidth)
    }
}

/// A menu's options on a panel: 28 pt lines, each with a square marker, the
/// chosen one filled with ink, and a count on the right when there is one.
/// The pointer washes a line.
struct SquareMenuList: View {
    struct Item {
        var label: String
        var checked: Bool
        var count: String?
    }

    let items: [Item]
    var minWidth: CGFloat = 190
    var pick: (Int) -> Void

    var body: some View {
        SquarePanel(padding: EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)) {
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    SquareMenuLine(item: items[i]) { pick(i) }
                }
            }
            .frame(minWidth: minWidth)
        }
        .fixedSize()
    }
}

private struct SquareMenuLine: View {
    let item: SquareMenuList.Item
    let pick: () -> Void
    @Environment(\.squarePose) private var pose
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(item.checked ? DesignTokens.Colors.ink : .clear)
                    .overlay(Rectangle().strokeBorder(item.checked ? DesignTokens.Colors.ink : DesignTokens.Colors.ruleControl,
                                                      lineWidth: DesignTokens.hairline))
                    .frame(width: 10, height: 10)
                Text(item.label)
                    .font(Square.mono(Square.controlSize))
                    .foregroundStyle(DesignTokens.Colors.ink)
                    .centredLetters(item.label)
                Spacer(minLength: 12)
                if let count = item.count {
                    Text(count).font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Rectangle().fill(pose.hot(hovering) ? DesignTokens.Colors.inkA08 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(item.checked ? .isSelected : [])
    }
}

/// A list's filter: a square button naming what it filters by, with its
/// menu under it. Once something is picked it inverts to the slab, shows the
/// pick and grows a cross that clears it.
struct SquareFilter<Popover: View>: View {
    let label: String
    var icon: String?
    var active = false
    var clear: () -> Void = {}
    @Binding var open: Bool
    @ViewBuilder var popover: () -> Popover

    var body: some View {
        HStack(spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 7) {
                    if let icon { SquareIcon(icon, size: 13) }
                    if icon == nil || active { Text(label) }
                    if icon == nil { SquareIcon("akar-chevron-down", size: 9) }
                }
            }
            .buttonStyle(SquareButtonStyle(kind: active ? .primary : .outline))
            .help(label)
            if active {
                Button(action: clear) {
                    SquareIcon("akar-cross", size: 8)
                        .foregroundStyle(DesignTokens.Colors.onSlab)
                        .frame(width: 22, height: SquareButtonStyle.height)
                        .background(DesignTokens.Colors.slab)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(DesignTokens.Colors.onSlab.opacity(0.28)).frame(width: DesignTokens.hairline)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("clear")
                .accessibilityLabel("clear \(label)")
            }
        }
        .squarePopover(isPresented: $open, content: popover)
    }
}

/// A question that has to be answered before something is destroyed: what
/// will happen in mono, what it means in SF, and the answers on the right,
/// the destructive one primary. It floats under the button that asked.
struct SquareConfirm<Answers: View>: View {
    let title: String
    var detail: String?
    var width: CGFloat = 280
    @ViewBuilder var answers: Answers

    var body: some View {
        SquarePanel(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Square.mono(13)).foregroundStyle(DesignTokens.Colors.ink)
                if let detail {
                    Text(detail).font(Square.sans(12)).foregroundStyle(DesignTokens.Colors.ink2).padding(.top, 4)
                }
                HStack(spacing: 8) { answers }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Every delete's question: what goes, that it can't be recovered, and
/// cancel or the delete itself.
struct SquareDeleteConfirm: View {
    let title: String
    var detail = SquareDeleteConfirm.gone(1)
    var confirm = "delete"
    let cancel: () -> Void
    let delete: () -> Void

    /// That what goes can't be got back, for one thing or several.
    static func gone(_ count: Int) -> String {
        count == 1 ? "it can't be recovered." : "they can't be recovered."
    }

    var body: some View {
        SquareConfirm(title: title, detail: detail) {
            Button("cancel", action: cancel).buttonStyle(SquareButtonStyle())
            Button(confirm, action: delete).buttonStyle(SquareButtonStyle(kind: .primary))
        }
    }
}

extension View {
    /// Asks before `delete` runs, on a popup under this view. Nothing is
    /// deleted without asking.
    func squareConfirmDelete(isPresented: Binding<Bool>, title: String, detail: String = SquareDeleteConfirm.gone(1),
                             confirm: String = "delete", delete: @escaping () -> Void) -> some View {
        squarePopover(isPresented: isPresented) {
            SquareDeleteConfirm(title: title, detail: detail, confirm: confirm, cancel: { isPresented.wrappedValue = false }) {
                isPresented.wrappedValue = false
                delete()
            }
        }
    }
}

/// The (?) after a label. A click opens its note under it, on a panel.
struct SquareHelp: View {
    let text: String
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(open || hovering ? DesignTokens.Colors.ink : DesignTokens.Colors.ink3)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("about this")
        .squarePopover(isPresented: $open) { SquareHelpNote(text: text) }
    }
}

struct SquareHelpNote: View {
    let text: String

    var body: some View {
        SquarePanel(padding: EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)) {
            Text(text)
                .font(Square.sans(11))
                .lineSpacing(3)
                .foregroundStyle(DesignTokens.Colors.ink2)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if DEBUG
struct SquareChoiceSpecimen: View {
    @State private var theme = "system"
    @State private var position = "bottom"

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "rest") { SquareChoice(selection: $theme, options: ["system", "light", "dark"]) }
            SquareSpecimenLine(name: "hover", pose: .hover) { SquareChoice(selection: .constant("system"), options: ["system", "light", "dark"]) }
            SquareSpecimenLine(name: "four") { SquareChoice(selection: $position, options: ["left", "top", "bottom", "right"]) }
            SquareSpecimenLine(name: "two") { SquareChoice(selection: .constant("ask"), options: ["ask", "never"]) }
        }
    }
}

struct SquareMenuSpecimen: View {
    @State private var microphone = "system default"
    @State private var key = "return"

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "rest") {
                SquareMenu(selection: $microphone, options: ["system default", "macbook pro microphone", "airpods pro"], minWidth: 230)
            }
            SquareSpecimenLine(name: "hover", pose: .hover) { SquareMenu(selection: $key, options: ["return", "tab"], minWidth: 180) }
            SquareSpecimenLine(name: "open") {
                SquareMenuList(items: [
                    .init(label: "keep everything", checked: true),
                    .init(label: "the last 500", checked: false),
                    .init(label: "a month", checked: false),
                    .init(label: "nothing · never keep", checked: false),
                ], minWidth: 230) { _ in }
            }
            SquareSpecimenLine(name: "hover line", pose: .hover) {
                SquareMenuList(items: [.init(label: "return", checked: true)], minWidth: 180) { _ in }
            }
            SquareSpecimenLine(name: "with counts") {
                SquareMenuList(items: [
                    .init(label: "any app", checked: true, count: "563"),
                    .init(label: "slack", checked: false, count: "212"),
                    .init(label: "mail", checked: false, count: "97"),
                ], minWidth: 232) { _ in }
            }
        }
    }
}

struct SquareFilterSpecimen: View {
    @State private var appOpen = false
    @State private var app = "any app"
    @State private var whenOpen = false

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "try it") {
                SquareFilter(label: app == "any app" ? "app" : app, active: app != "any app", clear: { app = "any app" }, open: $appOpen) {
                    SquareMenuList(items: ["any app", "slack", "mail", "notes"].map { .init(label: $0, checked: $0 == app) }, minWidth: 232) { i in
                        app = ["any app", "slack", "mail", "notes"][i]
                        appOpen = false
                    }
                }
            }
            SquareSpecimenLine(name: "rest") {
                SquareFilter(label: "who", open: .constant(false)) { EmptyView() }
                SquareFilter(label: "when", icon: "akar-clock", open: $whenOpen) { EmptyView() }
            }
            SquareSpecimenLine(name: "picked") {
                SquareFilter(label: "slack", active: true, open: .constant(false)) { EmptyView() }
                SquareFilter(label: "this week", icon: "akar-clock", active: true, open: .constant(false)) { EmptyView() }
            }
        }
    }
}

struct SquareConfirmSpecimen: View {
    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "delete") {
                SquareDeleteConfirm(title: "delete this dictation?", cancel: {}, delete: {})
            }
            SquareSpecimenLine(name: "delete all") {
                SquareDeleteConfirm(title: "delete all 1,201 dictations?", detail: SquareDeleteConfirm.gone(1201), confirm: "delete all", cancel: {}, delete: {})
            }
            SquareSpecimenLine(name: "with audio") {
                SquareConfirm(title: "delete this meeting?", detail: "it has 11m 04s of audio.", width: 300) {
                    Button("cancel") {}.buttonStyle(SquareButtonStyle())
                    Button("audio only") {}.buttonStyle(SquareButtonStyle())
                    Button("everything") {}.buttonStyle(SquareButtonStyle(kind: .primary))
                }
            }
            SquareSpecimenLine(name: "help") {
                HStack(spacing: 6) {
                    Text("pin").font(Square.mono(13)).foregroundStyle(DesignTokens.Colors.ink)
                    SquareHelp(text: "fn again to finish")
                }
                SquareHelpNote(text: "a call is detected when another app opens the microphone. the last two minutes are held in memory so a meeting does not start late, and are thrown away unless you say record.")
            }
        }
    }
}

#Preview("choice") { SquareChoiceSpecimen() }
#Preview("menu") { SquareMenuSpecimen() }
#Preview("filter") { SquareFilterSpecimen() }
#Preview("confirm and help") { SquareConfirmSpecimen() }
#endif
