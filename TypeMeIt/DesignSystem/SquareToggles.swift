import SwiftUI

/// The square switch: a 30 × 16 outline on the control rule with a 10 pt
/// knob. On fills with the slab and moves the knob right, in on-slab. The
/// knob crosses in the square parts' hard steps while the track dithers
/// solid, or empty going off. Disabled fades to 40%.
struct SquareSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SquareSwitch(configuration: configuration)
    }
}

private struct SquareSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.labelsVisibility) private var labels
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The track's fill, 0...16, and how far across the knob is, 0...1,
    /// while it moves; nil once it has landed where `isOn` puts it.
    @State private var moving: (level: Int, across: CGFloat)?
    @State private var run: Task<Void, Never>?

    private static let width: CGFloat = 30
    private static let height: CGFloat = 16
    private static let knob: CGFloat = 10
    private static var inset: CGFloat { (height - knob) / 2 }
    private static var travel: CGFloat { width - knob - 2 * inset }

    var body: some View {
        HStack(spacing: 8) {
            if labels != .hidden { configuration.label }
            Button { configuration.isOn.toggle() } label: { track }
                .buttonStyle(.plain)
                .accessibilityRepresentation {
                    Toggle(isOn: configuration.$isOn) { configuration.label }
                }
        }
    }

    private var track: some View {
        let on = configuration.isOn
        let level = moving?.level ?? (on ? 16 : 0)
        let across = moving?.across ?? (on ? 1 : 0)
        return SquareDither(level: level, color: DesignTokens.Colors.slab)
            .overlay(Rectangle().strokeBorder(level >= 16 ? DesignTokens.Colors.slab : DesignTokens.Colors.ruleControl, lineWidth: DesignTokens.hairline))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(level >= 8 ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ruleControl)
                    .frame(width: SquareSwitch.knob, height: SquareSwitch.knob)
                    .offset(x: (SquareSwitch.inset + SquareSwitch.travel * across).rounded())
            }
            .frame(width: SquareSwitch.width, height: SquareSwitch.height)
            .opacity(enabled ? 1 : 0.4)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onChange(of: on) { was, now in flip(from: was, to: now) }
            .onDisappear { run?.cancel() }
    }

    /// Steps the knob across and the fill in or out, from wherever a flip
    /// still running has got to.
    private func flip(from was: Bool, to now: Bool) {
        run?.cancel()
        run = nil
        guard !reduceMotion else {
            moving = nil
            return
        }
        let start = moving ?? (level: was ? 16 : 0, across: was ? 1 : 0)
        let end: (level: Int, across: CGFloat) = (now ? 16 : 0, now ? 1 : 0)
        run = Task {
            var step = 0
            guard await SquarePixel.run({
                step += 1
                moving = (SquarePixel.level(from: start.level, to: end.level, step: step),
                          start.across + (end.across - start.across) * CGFloat(step) / CGFloat(SquarePixel.steps))
                return step < SquarePixel.steps
            }) else { return }
            moving = nil
            run = nil
        }
    }
}

/// The square tick: a 14 pt box on the control rule, filled with the slab
/// and a check when on. The fill dithers in over the square parts' steps,
/// and out again going off; the check shows once it is solid. The pointer
/// takes an empty box's edge to ink.
/// `faint` is a list's select box, on an ink-a48 edge until the pointer
/// comes.
struct SquareTickStyle: ToggleStyle {
    var faint = false

    func makeBody(configuration: Configuration) -> some View {
        SquareTick(configuration: configuration, faint: faint)
    }
}

private struct SquareTick: View {
    let configuration: ToggleStyleConfiguration
    let faint: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.squarePose) private var pose
    @Environment(\.labelsVisibility) private var labels
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    /// The fill, 0...16, while it dithers in or out; nil once it has landed.
    @State private var moving: Int?
    @State private var run: Task<Void, Never>?

    private var level: Int { moving ?? (configuration.isOn ? 16 : 0) }

    var body: some View {
        let on = configuration.isOn
        HStack(spacing: 8) {
            Button { configuration.isOn.toggle() } label: {
                Rectangle()
                    .fill(DesignTokens.Colors.paper)
                    .overlay { SquareDither(level: level, color: DesignTokens.Colors.slab) }
                    .overlay(Rectangle().strokeBorder(edge, lineWidth: DesignTokens.hairline))
                    .overlay { if on && level >= 16 { SquareIcon("akar-check", size: 9).foregroundStyle(DesignTokens.Colors.onSlab) } }
                    .frame(width: 14, height: 14)
                    .opacity(enabled ? 1 : 0.4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
            if labels != .hidden { configuration.label }
        }
        .onChange(of: on) { was, now in fill(from: was, to: now) }
        .onDisappear { run?.cancel() }
    }

    private func fill(from was: Bool, to now: Bool) {
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

    private var edge: Color {
        if level >= 16 { return DesignTokens.Colors.slab }
        if enabled && pose.hot(hovering) { return DesignTokens.Colors.ink }
        return faint ? DesignTokens.Colors.inkA48 : DesignTokens.Colors.ruleControl
    }
}

#if DEBUG
struct SquareSwitchSpecimen: View {
    @State private var sounds = true
    @State private var dock = false

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "off · on") {
                Toggle("dock icon", isOn: $dock)
                Toggle("sounds", isOn: $sounds)
            }
            SquareSpecimenLine(name: "disabled") {
                Toggle("off", isOn: .constant(false))
                Toggle("on", isOn: .constant(true))
            }
            .disabled(true)
        }
        .toggleStyle(SquareSwitchStyle())
        .labelsHidden()
    }
}

struct SquareTickSpecimen: View {
    @State private var picked = true

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "disabled") { ticks(faint: false) }
                .disabled(true)
            SquareSpecimenLine(name: "select box") { ticks(faint: true) }
            SquareSpecimenLine(name: "try it") {
                Toggle("mcp", isOn: $picked).toggleStyle(SquareTickStyle())
                    .font(Square.mono(12))
                    .foregroundStyle(DesignTokens.Colors.ink)
            }
        }
    }

    private func ticks(faint: Bool) -> some View {
        HStack(spacing: 10) {
            Toggle("off", isOn: .constant(false))
            Toggle("on", isOn: .constant(true))
        }
        .toggleStyle(SquareTickStyle(faint: faint))
        .labelsHidden()
    }
}

#Preview("switch") { SquareSwitchSpecimen() }
#Preview("tick") { SquareTickSpecimen() }
#endif
