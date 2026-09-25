import SwiftUI

/// The square switch: a 30 × 16 outline on the control rule with a 10 pt
/// knob. On fills with the slab and slides the knob right, in on-slab.
/// Disabled fades to 40%.
struct SquareSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SquareSwitch(configuration: configuration)
    }
}

private struct SquareSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.labelsVisibility) private var labels

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
        return Rectangle()
            .fill(on ? DesignTokens.Colors.slab : .clear)
            .overlay(Rectangle().strokeBorder(on ? DesignTokens.Colors.slab : DesignTokens.Colors.ruleControl, lineWidth: DesignTokens.hairline))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(on ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ruleControl)
                    .frame(width: SquareSwitch.knob, height: SquareSwitch.knob)
                    .offset(x: SquareSwitch.inset + (on ? SquareSwitch.travel : 0))
            }
            .frame(width: SquareSwitch.width, height: SquareSwitch.height)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: DesignTokens.Duration.n1), value: on)
    }
}

/// The square tick: a 14 pt box on the control rule, filled with the slab
/// and a check when on. The pointer takes an empty box's edge to ink.
/// `faint` is a list's select box, on an ink-a32 edge until the pointer
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
    @State private var hovering = false

    var body: some View {
        let on = configuration.isOn
        HStack(spacing: 8) {
            Button { configuration.isOn.toggle() } label: {
                Rectangle()
                    .fill(on ? DesignTokens.Colors.slab : DesignTokens.Colors.paper)
                    .overlay(Rectangle().strokeBorder(edge, lineWidth: DesignTokens.hairline))
                    .overlay { if on { SquareIcon("akar-check", size: 9).foregroundStyle(DesignTokens.Colors.onSlab) } }
                    .frame(width: 14, height: 14)
                    .opacity(enabled ? 1 : 0.4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: DesignTokens.Duration.n1), value: hovering)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
            if labels != .hidden { configuration.label }
        }
    }

    private var edge: Color {
        if configuration.isOn { return DesignTokens.Colors.slab }
        if enabled && pose.hot(hovering) { return DesignTokens.Colors.ink }
        return faint ? DesignTokens.Colors.inkA32 : DesignTokens.Colors.ruleControl
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
            ForEach(SquarePose.allCases.filter { $0 != .pressed }, id: \.self) { pose in
                SquareSpecimenLine(name: pose.name, pose: pose) { ticks(faint: false) }
            }
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
