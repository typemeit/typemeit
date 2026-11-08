import SwiftUI

/// The 🌐 key step's picture: Keyboard settings, drawn, with a pointer that
/// opens the "Press 🌐 key to" menu and picks Do Nothing, on a loop. With
/// reduce motion on it holds on the open menu with Do Nothing highlighted.
struct FnKeyAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    // Laid out in points at the size System Settings draws them, then scaled to fit.
    private static let size = CGSize(width: 477, height: 244)
    private static let rowHeight: CGFloat = 40
    private static let cardTop: CGFloat = 14
    private static let inset: CGFloat = 14
    private static let fnRowIndex = 2
    private static let rowCount = 4
    private static var menuItems: [Text] {
        [Text("Change Input Source"), Text("Show Emoji & Symbols"),
         Text("Start Dictation (Press \(Image(systemName: "globe")) Twice)"), Text("Do Nothing")]
    }
    private static let startValue = 1
    private static let pickedValue = 3
    private static let itemHeight: CGFloat = 22
    private static let menuPadding: CGFloat = 5
    private static let menuWidth: CGFloat = 250
    private static let stepperSide: CGFloat = 22

    /// One loop, in seconds, and when each thing in it happens.
    private static let period = 6.0
    private enum Beat {
        static let appear = 0.3
        static let setOff = 0.4
        static let reachStepper = 1.25
        static let openMenu = 1.35
        static let leaveStepper = 1.6
        static let reachPick = 2.4
        static let pick = 2.75
        static let closeMenu = 2.87
        static let drift = 3.1
        static let gone = 3.9
        static let reset = 5.2
    }
    /// How long the pointer takes to fade in or out.
    private static let fade = 0.3

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? Beat.reachPick : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            GeometryReader { geo in
                let scale = geo.size.width / Self.size.width
                frame(at: t)
                    .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                    .scaleEffect(scale, anchor: .topLeading)
            }
            .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        }
        .accessibilityElement()
        .accessibilityLabel("keyboard settings, press globe key to, set to do nothing")
    }

    // MARK: - One frame

    private func frame(at t: Double) -> some View {
        let menuOpen = t >= Beat.openMenu && t < Beat.closeMenu
        let picked = t >= Beat.pick && t < Beat.reset
        let pointer = pointerPosition(at: t)
        let highlighted = menuOpen ? Self.menuItems.indices.first { itemFrame($0).contains(pointer) } : nil
        // macOS blinks the chosen item off once before the menu closes.
        let blink = t >= Beat.pick && t < Beat.pick + (Beat.closeMenu - Beat.pick) / 2
        return ZStack(alignment: .topLeading) {
            palette.pane
            card(value: picked ? Self.pickedValue : Self.startValue)
            outline
            if menuOpen {
                menu(checked: Self.startValue, highlighted: blink ? nil : highlighted)
                    .transition(.opacity)
            }
            Pointer()
                .opacity(pointerOpacity(at: t))
                .offset(x: pointer.x, y: pointer.y)
        }
        .animation(.easeOut(duration: 0.12), value: menuOpen)
        .clipped()
    }

    // MARK: - Settings card

    private func card(value: Int) -> some View {
        VStack(spacing: 0) {
            row("Keyboard brightness") { slider }
            divider
            row("Turn keyboard backlight off after inactivity") { popup(Text("After 1 Minute")) }
            divider
            row(Text("Press \(Image(systemName: "globe")) key to")) { popup(Self.menuItems[value]) }
            divider
            row("Keyboard navigation") { toggle }
        }
        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.cardEdge, lineWidth: 0.5))
        .padding(.horizontal, Self.inset)
        .offset(y: Self.cardTop)
    }

    private func row(_ label: String, @ViewBuilder trailing: () -> some View) -> some View {
        row(Text(label), trailing: trailing)
    }

    private func row(_ label: Text, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            label.font(.system(size: 13)).foregroundStyle(palette.text)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
    }

    private var divider: some View {
        palette.divider.frame(height: 0.5).padding(.horizontal, 12)
    }

    private func popup(_ value: Text) -> some View {
        HStack(spacing: 8) {
            value.font(.system(size: 13)).foregroundStyle(palette.text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(palette.text)
                .frame(width: Self.stepperSide, height: Self.stepperSide)
                .background(palette.control, in: Circle())
        }
    }

    private var slider: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(palette.control).frame(width: 180, height: 5)
            Capsule().fill(Color.accentColor).frame(width: 120, height: 5)
            Circle().fill(.white).frame(width: 18, height: 18).shadow(radius: 1).offset(x: 111)
        }
    }

    private var toggle: some View {
        Capsule().fill(palette.control).frame(width: 38, height: 22)
            .overlay(alignment: .leading) { Circle().fill(.white).frame(width: 20, height: 20).padding(.leading, 1) }
    }

    /// The row the step is about, framed in ink as the old screenshot was.
    private var outline: some View {
        let top = Self.cardTop + CGFloat(Self.fnRowIndex) * Self.rowHeight
        return Rectangle()
            .strokeBorder(DesignTokens.Colors.ink, lineWidth: 3)
            .frame(width: Self.size.width - 2 * Self.inset + 8, height: Self.rowHeight + 8)
            .offset(x: Self.inset - 4, y: top - 4)
    }

    // MARK: - Menu

    private var menuOrigin: CGPoint {
        CGPoint(x: Self.size.width - Self.inset - 8 - Self.menuWidth,
                y: Self.cardTop + CGFloat(Self.fnRowIndex + 1) * Self.rowHeight + 2)
    }

    private func itemFrame(_ index: Int) -> CGRect {
        CGRect(x: menuOrigin.x, y: menuOrigin.y + Self.menuPadding + CGFloat(index) * Self.itemHeight,
               width: Self.menuWidth, height: Self.itemHeight)
    }

    private func menu(checked: Int, highlighted: Int?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.menuItems.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(index == checked ? 1 : 0)
                        .frame(width: 14)
                    Self.menuItems[index].font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(index == highlighted ? .white : palette.text)
                .padding(.horizontal, 6)
                .frame(height: Self.itemHeight)
                .background(index == highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(Self.menuPadding)
        .frame(width: Self.menuWidth)
        .background(palette.menu, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.cardEdge, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .offset(x: menuOrigin.x, y: menuOrigin.y)
    }

    // MARK: - Pointer

    /// Where the pointer's tip is: it fades in under the card, curves up to
    /// the popup's arrows, down the menu to Do Nothing, then drifts off as it
    /// fades, so the loop never has to carry it back.
    private func pointerPosition(at t: Double) -> CGPoint {
        let start = CGPoint(x: 230, y: 214)
        let stepper = CGPoint(x: Self.size.width - Self.inset - 12 - Self.stepperSide / 2,
                              y: Self.cardTop + (CGFloat(Self.fnRowIndex) + 0.5) * Self.rowHeight)
        let pick = CGPoint(x: menuOrigin.x + 110, y: itemFrame(Self.pickedValue).midY)
        let away = CGPoint(x: pick.x - 40, y: pick.y + 24)
        switch t {
        case ..<Beat.setOff: return start
        case ..<Beat.reachStepper: return arc(start, stepper, bend: -40, progress(t, Beat.setOff, Beat.reachStepper))
        case ..<Beat.leaveStepper: return stepper
        case ..<Beat.reachPick: return arc(stepper, pick, bend: 24, progress(t, Beat.leaveStepper, Beat.reachPick))
        case ..<Beat.drift: return pick
        default: return arc(pick, away, bend: 0, progress(t, Beat.drift, Beat.gone))
        }
    }

    private func pointerOpacity(at t: Double) -> Double {
        if t < Beat.appear { return progress(t, Beat.appear - Self.fade, Beat.appear) }
        if t < Beat.gone - Self.fade { return 1 }
        return 1 - progress(t, Beat.gone - Self.fade, Beat.gone)
    }

    private func progress(_ t: Double, _ from: Double, _ to: Double) -> Double {
        min(max((t - from) / (to - from), 0), 1)
    }

    /// From `a` to `b` along a curve bowed `bend` points to the side, with
    /// the speed of a hand: quick to set off, slow to land.
    private func arc(_ a: CGPoint, _ b: CGPoint, bend: CGFloat, _ p: Double) -> CGPoint {
        let eased = CGFloat(p * p * p * (p * (p * 6 - 15) + 10))
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 1)
        let control = CGPoint(x: (a.x + b.x) / 2 - dy / length * bend, y: (a.y + b.y) / 2 + dx / length * bend)
        let u = 1 - eased
        return CGPoint(x: u * u * a.x + 2 * u * eased * control.x + eased * eased * b.x,
                       y: u * u * a.y + 2 * u * eased * control.y + eased * eased * b.y)
    }

    // MARK: - Colours

    private var palette: Palette { scheme == .dark ? .dark : .light }

    /// System Settings' own greys, not the app's tokens: the picture is of macOS.
    private struct Palette {
        let pane, card, cardEdge, divider, control, menu, text: Color

        static let dark = Palette(pane: Color(white: 0.16), card: Color(white: 0.2), cardEdge: Color(white: 1, opacity: 0.08),
                                  divider: Color(white: 1, opacity: 0.08), control: Color(white: 1, opacity: 0.14),
                                  menu: Color(white: 0.22), text: Color(white: 0.92))
        static let light = Palette(pane: Color(white: 0.93), card: .white, cardEdge: Color(white: 0, opacity: 0.08),
                                   divider: Color(white: 0, opacity: 0.08), control: Color(white: 0, opacity: 0.08),
                                   menu: Color(white: 0.97), text: Color(white: 0.1))
    }
}

/// The macOS arrow pointer, tip at the origin.
private struct Pointer: View {
    var body: some View {
        let arrow = Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: 0, y: 17))
            p.addLine(to: CGPoint(x: 4.2, y: 13.2))
            p.addLine(to: CGPoint(x: 7, y: 19.6))
            p.addLine(to: CGPoint(x: 9.6, y: 18.5))
            p.addLine(to: CGPoint(x: 6.8, y: 12.2))
            p.addLine(to: CGPoint(x: 12.2, y: 12.2))
            p.closeSubpath()
        }
        ZStack {
            arrow.fill(.black)
            arrow.stroke(.white, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
        .frame(width: 14, height: 21, alignment: .topLeading)
        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }
}

#Preview("fn key") { FnKeyAnimation().frame(width: 464).padding() }
