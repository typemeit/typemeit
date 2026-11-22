import SwiftUI

/// The choice's coordinate space, where the slab and the segments' frames are measured.
private let squareChoiceSpace = "square-choice"

/// The square choice: options side by side in one ink outline, split by
/// ink-a20 hairlines, the chosen one inverted to the slab. The pointer
/// washes the others. Choosing another moves the slab there as the tabs'
/// does, in hard steps with a dithered ghost left behind.
struct SquareChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    var label: (Value) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Each segment's frame in the choice.
    @State private var frames: [Int: CGRect] = [:]
    @State private var motion = SquareSlabMotion()
    @State private var jump: Task<Void, Never>?

    private var picked: Int? { options.firstIndex(of: selection) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { i, option in
                if i > 0 { Rectangle().fill(DesignTokens.Colors.inkA20).frame(width: DesignTokens.hairline) }
                SquareSegment(text: label(option), chosen: option == selection,
                              onSlab: motion.covers(frames[i]) ?? (i == picked)) { selection = option }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(squareChoiceSpace)) } action: { frame in
                        frames[i] = frame
                        if i == picked && jump == nil { motion.slab = frame }
                    }
            }
        }
        .background(alignment: .topLeading) { SquareSlabLayer(motion: motion) }
        .coordinateSpace(.named(squareChoiceSpace))
        .padding(DesignTokens.hairline)
        .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
        .fixedSize()
        .onChange(of: selection) { _, _ in jumpSlab() }
    }

    private func jumpSlab() {
        jump?.cancel()
        jump = nil
        guard let index = picked, let target = frames[index],
              motion.start(to: target, reduceMotion: reduceMotion) else { return }
        jump = Task {
            guard await SquarePixel.run({ motion.advance() }) else { return }
            motion.settle(at: frames[index])
            jump = nil
        }
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
    /// The slab is under this segment's middle, now or on its way.
    let onSlab: Bool
    let choose: () -> Void
    @Environment(\.squarePose) private var pose
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            Text(text)
                .font(Square.mono(Square.controlSize))
                .centredLetters(text)
                .foregroundStyle(onSlab ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink2)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Rectangle().fill(onSlab || !pose.hot(hovering) ? Color.clear : DesignTokens.Colors.inkA04))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Where the cloud sits, chosen on a drawing of the screen: its outline and
/// a menu bar with the Apple menu, with a dot at each place the cloud can go.
/// The chosen dot is ink and a size up; the pointer darkens the others.
/// Choosing another place moves the ink dot there in the square parts'
/// hard steps, and the place it left keeps a dithered ghost of it.
struct SquareScreenPicker: View {
    @Binding var selection: CloudPosition
    @Environment(\.squarePose) private var pose
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: CloudPosition?
    /// Where the ink dot is drawn while it moves; nil once it has landed.
    @State private var moving: CGPoint?
    /// The place it left, while its ghost fades, and how many of 16 cells are inked.
    @State private var ghost: CGPoint?
    @State private var ghostLevel = 0
    @State private var run: Task<Void, Never>?

    private static let width: CGFloat = 112
    /// The Mac's own screen shape, 1512 by 982 on a 14-inch MacBook Pro.
    private static var height: CGFloat {
        NSScreen.main.map { width * $0.frame.height / $0.frame.width } ?? width * 10 / 16
    }
    /// Far thicker than the Mac's, which at this size would be a hairline.
    private static let menuBar: CGFloat = 10
    private static let appleSize: CGFloat = 7
    /// The Apple menu sits this far in from the screen's side.
    private static let menuBarInset: CGFloat = 6
    /// How far a dot sits in from the edge it is on.
    private static let inset: CGFloat = 13
    private static let dot: CGFloat = 7
    private static let target: CGFloat = 24

    var body: some View {
        ZStack(alignment: .top) {
            Image(systemName: "apple.logo")
                .font(.system(size: SquareScreenPicker.appleSize))
                .foregroundStyle(DesignTokens.Colors.ink)
                .padding(.leading, SquareScreenPicker.menuBarInset)
                .frame(maxWidth: .infinity, maxHeight: SquareScreenPicker.menuBar, alignment: .leading)
                .background(DesignTokens.Colors.inkA08)
            ForEach(CloudPosition.allCases, id: \.self) { position in
                dot(position).position(SquareScreenPicker.centre(of: position))
            }
            if let ghost, ghostLevel > 0 {
                SquareDither(level: ghostLevel, color: DesignTokens.Colors.ink)
                    .frame(width: SquareScreenPicker.chosenDot, height: SquareScreenPicker.chosenDot)
                    .clipShape(Circle())
                    .position(ghost)
            }
            Circle()
                .fill(DesignTokens.Colors.ink)
                .frame(width: SquareScreenPicker.chosenDot, height: SquareScreenPicker.chosenDot)
                .position(moving ?? SquareScreenPicker.centre(of: selection))
                .allowsHitTesting(false)
        }
        .frame(width: SquareScreenPicker.width, height: SquareScreenPicker.height)
        .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ruleControl, lineWidth: DesignTokens.hairline))
        .fixedSize()
        .onChange(of: selection) { was, now in move(from: was, to: now) }
        .onDisappear { run?.cancel() }
    }

    private static var chosenDot: CGFloat { dot * 1.4 }

    /// Steps the ink dot to its new place, from wherever a move still
    /// running has got to, and fades the ghost it leaves.
    private func move(from was: CloudPosition, to now: CloudPosition) {
        run?.cancel()
        run = nil
        guard !reduceMotion else {
            moving = nil
            ghost = nil
            return
        }
        let from = moving ?? SquareScreenPicker.centre(of: was), to = SquareScreenPicker.centre(of: now)
        ghost = from
        ghostLevel = SquarePixel.ghostStart
        run = Task {
            var step = 0
            guard await SquarePixel.run({
                if step < SquarePixel.steps {
                    step += 1
                    moving = SquarePixel.point(from: from, to: to, step: step)
                }
                ghostLevel = max(0, ghostLevel - SquarePixel.ghostThin)
                return step < SquarePixel.steps || ghostLevel > 0
            }) else { return }
            moving = nil
            ghost = nil
            run = nil
        }
    }

    /// Where `OverlayPanel` puts the cloud: the sides halfway down the space
    /// under the menu bar, the top just under the menu bar, the bottom at the
    /// foot of the screen.
    private static func centre(of position: CloudPosition) -> CGPoint {
        let middle = (menuBar + height) / 2
        return switch position {
        case .left: CGPoint(x: inset, y: middle)
        case .top: CGPoint(x: width / 2, y: menuBar + inset)
        case .centre: CGPoint(x: width / 2, y: height - inset)
        case .right: CGPoint(x: width - inset, y: middle)
        }
    }

    private func dot(_ position: CloudPosition) -> some View {
        let chosen = position == selection
        // The chosen place's own dot stays plain: the ink dot drawn over the
        // picker covers it once it lands.
        let fill = pose.hot(hovered == position) && !chosen ? DesignTokens.Colors.inkA64 : DesignTokens.Colors.inkA32
        return Button { selection = position } label: {
            Circle()
                .fill(fill)
                .frame(width: SquareScreenPicker.dot, height: SquareScreenPicker.dot)
                .frame(width: SquareScreenPicker.target, height: SquareScreenPicker.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? position : (hovered == position ? nil : hovered) }
        .accessibilityLabel(position.label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A square popup: the value and a chevron on the control rule. Under the
/// pointer its edge goes to ink on a button's ink-a08 wash; while open the
/// edge stays ink. It is as wide as its longest option, so a click opens the
/// options joined to its bottom edge at its own width.
struct SquareMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    var label: (Value) -> String
    @State private var open = false
    @State private var hovering = false
    @State private var width: CGFloat = 0
    @Environment(\.squarePose) private var pose

    private var items: [SquareMenuList.Item] {
        options.map { SquareMenuList.Item(label: label($0), checked: $0 == selection) }
    }

    var body: some View {
        Button { open.toggle() } label: {
            let text = label(selection)
            ZStack {
                // The lines, unseen, set the width the open list will have.
                SquareMenuLines(items: items, pick: { _ in }).frame(height: 0).hidden()
                HStack(spacing: 10) {
                    Text(text).centredLetters(text)
                    Spacer(minLength: 0)
                    SquareIcon("akar-chevron-down", size: 10)
                }
                .padding(.leading, 8)
                .padding(.trailing, 7)
            }
            .fixedSize(horizontal: true, vertical: false)
            .font(Square.mono(Square.controlSize))
            .foregroundStyle(DesignTokens.Colors.ink)
            .frame(height: SquareButtonStyle.height)
            .overlay(Rectangle().strokeBorder(open || pose.hot(hovering) ? DesignTokens.Colors.ink : DesignTokens.Colors.ruleControl,
                                              lineWidth: DesignTokens.hairline))
            .background(!open && pose.hot(hovering) ? DesignTokens.Colors.inkA08 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .squarePopover(isPresented: $open, attached: true) {
            SquareMenuList(items: items, minWidth: width) { i in
                selection = options[i]
                open = false
            }
        }
    }
}

extension SquareMenu where Value == String {
    init(selection: Binding<String>, options: [String]) {
        self.init(selection: selection, options: options, label: { $0 })
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
        /// A line under the one before it, such as a channel under its app.
        var indent = false
        /// A line that stands for a kind, not a name, such as "unknown".
        var italic = false
    }

    let items: [Item]
    var minWidth: CGFloat = 190
    var pick: (Int) -> Void

    var body: some View {
        SquarePanel(padding: EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)) {
            SquareMenuLines(items: items, pick: pick).frame(minWidth: minWidth)
        }
        .fixedSize()
    }
}

/// A menu's lines without their panel, for a panel that holds more than the
/// lines, such as a field over them.
struct SquareMenuLines: View {
    let items: [SquareMenuList.Item]
    var pick: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                SquareMenuLine(item: items[i]) { pick(i) }
            }
        }
    }
}

/// One line of a menu: its box, ticked when checked, the label, and a count.
struct SquareMenuLine: View {
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
                    .italic(item.italic)
                    .foregroundStyle(DesignTokens.Colors.ink)
                    .centredLetters(item.label)
                Spacer(minLength: 0)
                if let count = item.count {
                    Text(count).font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3).padding(.leading, 12)
                }
            }
            .padding(.leading, item.indent ? 32 : 12)
            .padding(.trailing, 12)
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
/// pick and grows a cross that clears it. The slab dithers in over the
/// square parts' steps as the cross steps out from behind, and the other way
/// on clearing.
struct SquareFilter<Popover: View>: View {
    let label: String
    var active = false
    var clear: () -> Void = {}
    @Binding var open: Bool
    @ViewBuilder var popover: () -> Popover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The slab, 0...16, while it dithers in or out; nil once it has landed.
    @State private var moving: Int?
    @State private var run: Task<Void, Never>?

    private static var crossWidth: CGFloat { 22 }

    var body: some View {
        let level = moving ?? (active ? 16 : 0)
        HStack(spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 7) {
                    Text(label)
                    SquareIcon("akar-chevron-down", size: 9)
                }
            }
            .buttonStyle(SquareButtonStyle(kind: level >= 16 ? .primary : .outline))
            .background { if level > 0 && level < 16 { SquareDither(level: level, color: DesignTokens.Colors.slab) } }
            .help(label)
            if level > 0 {
                Button(action: clear) {
                    SquareIcon("akar-cross", size: 8)
                        .foregroundStyle(DesignTokens.Colors.onSlab)
                        .frame(width: Self.crossWidth, height: SquareButtonStyle.height)
                        .background(DesignTokens.Colors.slab)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(DesignTokens.Colors.onSlab.opacity(0.28)).frame(width: DesignTokens.hairline)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: (Self.crossWidth * CGFloat(level) / 16).rounded(), alignment: .leading)
                .clipped()
                .help("clear")
                .accessibilityLabel("clear \(label)")
            }
        }
        .squarePopover(isPresented: $open, content: popover)
        .onChange(of: active) { was, now in step(from: was, to: now) }
        .onDisappear { run?.cancel() }
    }

    private func step(from was: Bool, to now: Bool) {
        run?.cancel()
        run = nil
        guard !reduceMotion else {
            moving = nil
            return
        }
        let start = moving ?? (was ? 16 : 0), end = now ? 16 : 0
        run = Task {
            var step = 0
            guard await SquarePixel.run({
                step += 1
                moving = SquarePixel.level(from: start, to: end, step: step)
                return step < SquarePixel.steps
            }) else { return }
            moving = nil
            run = nil
        }
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

/// The delete of something whose audio can go on its own: while there is
/// audio, it says how much and offers it alone beside everything.
struct SquareAudioDeleteConfirm: View {
    let title: String
    /// How long the kept audio runs, such as "11m 04s"; nil when none was kept.
    let audio: String?
    let cancel: () -> Void
    let deleteAudio: () -> Void
    let deleteEverything: () -> Void

    private static let width: CGFloat = 300

    var body: some View {
        SquareConfirm(title: title, detail: audio.map { "it has \($0) of audio." }, width: SquareAudioDeleteConfirm.width) {
            Button("cancel", action: cancel).buttonStyle(SquareButtonStyle())
            if audio != nil {
                Button("audio only", action: deleteAudio).buttonStyle(SquareButtonStyle())
            }
            Button(audio == nil ? "delete" : "everything", action: deleteEverything)
                .buttonStyle(SquareButtonStyle(kind: .primary))
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
                .frame(width: 20, height: 20)
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
            SquareSpecimenLine(name: "three") { SquareChoice(selection: $theme, options: ["system", "light", "dark"]) }
            SquareSpecimenLine(name: "four") { SquareChoice(selection: $position, options: ["left", "top", "bottom", "right"]) }
            SquareSpecimenLine(name: "two") { SquareChoice(selection: .constant("ask"), options: ["ask", "never"]) }
        }
    }
}

struct SquareScreenPickerSpecimen: View {
    @State private var position = CloudPosition.centre

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "try it") { SquareScreenPicker(selection: $position) }
        }
    }
}

struct SquareMenuSpecimen: View {
    @State private var microphone = "system default"
    @State private var key = "return"

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "try it") {
                SquareMenu(selection: $microphone, options: ["system default", "macbook pro microphone", "airpods pro"])
            }
            SquareSpecimenLine(name: "short") { SquareMenu(selection: $key, options: ["return", "tab"]) }
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
                SquareAudioDeleteConfirm(title: "delete this meeting?", audio: "11m 04s", cancel: {}, deleteAudio: {}, deleteEverything: {})
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
