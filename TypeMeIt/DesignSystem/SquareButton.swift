import SwiftUI

/// The square button: a mono label on an ink outline. Primary fills with the
/// slab, quiet drops the outline, and disabled goes to ink-3 on a rule
/// outline whatever its kind. Under the pointer every kind's edge turns to
/// dashes: ink on an outlined or quiet button, on-slab inside a primary's
/// fill. Held, an outlined button takes an ink-a08 wash and a primary one eases
/// off its slab to ink-a64. On a slab surface every kind but quiet fills with
/// on-slab instead.
///
/// An icon goes in as a `Label`, with the icon a `SquareIcon` of 12.
struct SquareButtonStyle: ButtonStyle {
    enum Kind { case outline, primary, quiet }
    var kind: Kind = .outline
    /// For a button inside a line of text, such as stop in the sidebar.
    var small = false

    static let height: CGFloat = 26
    static let smallHeight: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        SquareButtonLabel(configuration: configuration, kind: kind, small: small)
    }
}

private struct SquareButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let kind: SquareButtonStyle.Kind
    let small: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.squarePose) private var pose
    @Environment(\.squareOnSlab) private var onSlab
    @State private var hovering = false

    private var size: CGFloat { small ? 11 : Square.controlSize }
    private var hot: Bool { enabled && pose.hot(hovering) }
    private var down: Bool { enabled && pose.down(configuration.isPressed) }
    private var inverse: Bool { onSlab && kind != .quiet }

    var body: some View {
        configuration.label
            .labelStyle(SquareButtonLabelStyle())
            .font(Square.mono(size))
            .lineLimit(1)
            .centredLowercase(size: size)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 9 : 10)
            .frame(height: small ? SquareButtonStyle.smallHeight : SquareButtonStyle.height)
            .background(Rectangle().fill(background))
            .overlay(Rectangle().strokeBorder(border, style: SquareEdge.style(dashed: hot)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        if !enabled { return DesignTokens.Colors.ink3 }
        if inverse { return DesignTokens.Colors.slab }
        switch kind {
        case .outline: return DesignTokens.Colors.ink
        case .primary: return DesignTokens.Colors.onSlab
        case .quiet:
            if onSlab { return DesignTokens.Colors.onSlab }
            return hot ? DesignTokens.Colors.ink : DesignTokens.Colors.ink2
        }
    }

    private var background: Color {
        guard enabled else { return .clear }
        if inverse {
            // The primary's step, taken off on-slab instead of the slab.
            return down ? DesignTokens.Colors.onSlab.opacity(0.64) : DesignTokens.Colors.onSlab
        }
        switch kind {
        case .primary:
            return down ? DesignTokens.Colors.inkA64 : DesignTokens.Colors.slab
        case .outline, .quiet:
            return down && !onSlab ? DesignTokens.Colors.inkA08 : .clear
        }
    }

    private var border: Color {
        if !enabled { return kind == .quiet ? .clear : DesignTokens.Colors.rule }
        if inverse { return hot ? DesignTokens.Colors.slab : .clear }
        switch kind {
        case .outline: return DesignTokens.Colors.ink
        case .primary: return hot ? DesignTokens.Colors.onSlab : .clear
        case .quiet:
            guard hot else { return .clear }
            return onSlab ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink2
        }
    }
}

private struct SquareButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
            configuration.title
        }
    }
}

/// A square icon button: ink-2, and under the pointer ink inside a dashed
/// ink-2 edge; held, an ink-a08 wash. Disabled fades to 40%.
struct SquareIconButtonStyle: ButtonStyle {
    var side: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        SquareIconButtonBody(configuration: configuration, side: side)
    }
}

private struct SquareIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let side: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.squarePose) private var pose
    @Environment(\.squareOnSlab) private var onSlab
    @State private var hovering = false

    private var hot: Bool { enabled && pose.hot(hovering) }
    private var down: Bool { enabled && pose.down(configuration.isPressed) }

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .frame(width: side, height: side)
            .background(Rectangle().fill(down ? (onSlab ? DesignTokens.Colors.onSlab.opacity(0.16) : DesignTokens.Colors.inkA08) : .clear))
            .overlay(Rectangle().strokeBorder(hot ? edge : .clear, style: SquareEdge.style(dashed: true)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        if onSlab { return DesignTokens.Colors.onSlab }
        return hot ? DesignTokens.Colors.ink : DesignTokens.Colors.ink2
    }

    private var edge: Color { onSlab ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink2 }
}

#if DEBUG
struct SquareButtonSpecimen: View {
    var body: some View {
        SquareSpecimen {
            ForEach(SquarePose.allCases, id: \.self) { pose in
                SquareSpecimenLine(name: pose.name, pose: pose) { kinds }
            }
            SquareSpecimenLine(name: "disabled") { kinds.disabled(true) }
            SquareSpecimenLine(name: "with icon") {
                Button {} label: { Label { Text("copy") } icon: { SquareIcon("akar-copy", size: 12) } }
                    .buttonStyle(SquareButtonStyle())
                Button {} label: { Label { Text("this week") } icon: { SquareIcon("akar-clock", size: 12) } }
                    .buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquareSpecimenLine(name: "small") {
                Button("show") {}.buttonStyle(SquareButtonStyle(small: true))
                Button("stop") {}.buttonStyle(SquareButtonStyle(kind: .primary, small: true))
            }
            SquareSpecimenLine(name: "on slab") {
                HStack(spacing: 6) {
                    Button("show") {}.buttonStyle(SquareButtonStyle())
                    Button("install") {}.buttonStyle(SquareButtonStyle(kind: .primary))
                }
                .padding(8)
                .background(DesignTokens.Colors.slab)
                .environment(\.squareOnSlab, true)
            }
        }
    }

    private var kinds: some View {
        HStack(spacing: 10) {
            Button("show") {}.buttonStyle(SquareButtonStyle())
            Button("stop") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            Button("cancel") {}.buttonStyle(SquareButtonStyle(kind: .quiet))
        }
    }
}

struct SquareIconButtonSpecimen: View {
    var body: some View {
        SquareSpecimen {
            ForEach(SquarePose.allCases, id: \.self) { pose in
                SquareSpecimenLine(name: pose.name, pose: pose) { icons }
            }
            SquareSpecimenLine(name: "disabled") { icons.disabled(true) }
            SquareSpecimenLine(name: "on slab") {
                HStack(spacing: 4) { icons }
                    .padding(6)
                    .background(DesignTokens.Colors.slab)
                    .environment(\.squareOnSlab, true)
            }
        }
    }

    private var icons: some View {
        HStack(spacing: 4) {
            ForEach(["akar-copy", "akar-pencil", "akar-trash-can", "akar-cross"], id: \.self) { name in
                Button {} label: { SquareIcon(name, size: name == "akar-cross" ? 10 : 14) }
                    .buttonStyle(SquareIconButtonStyle())
            }
        }
    }
}

#Preview("button") { SquareButtonSpecimen() }
#Preview("icon button") { SquareIconButtonSpecimen() }
#endif
