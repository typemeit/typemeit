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
            .environment(\.squareLabelLift, Square.drop(lowercase: true, size: size))
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

/// A square icon button: ink-2, and under the pointer ink on an ink-a08
/// square; held, ink-a12. Disabled fades to 40%.
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
            .background(Rectangle().fill(wash))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        if onSlab { return DesignTokens.Colors.onSlab }
        return hot ? DesignTokens.Colors.ink : DesignTokens.Colors.ink2
    }

    private var wash: Color {
        if onSlab { return down ? DesignTokens.Colors.onSlab.opacity(0.24) : hot ? DesignTokens.Colors.onSlab.opacity(0.16) : .clear }
        return down ? DesignTokens.Colors.inkA12 : hot ? DesignTokens.Colors.inkA08 : .clear
    }
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

/// Ways a text button could answer the pointer instead of the dashed edge,
/// to choose between: each draws an outlined and a primary button at rest,
/// under the pointer and held. The rest column answers the pointer live.
struct SquareButtonHoverSpecimen: View {
    var body: some View {
        SquareSpecimen {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 0) {
                    Text("").frame(width: 120, alignment: .leading)
                    ForEach(SquarePose.allCases, id: \.self) { pose in
                        Text(pose.name).frame(width: 150, alignment: .leading)
                    }
                }
                .font(Square.mono(11))
                .foregroundStyle(DesignTokens.Colors.ink3)
                ForEach(HoverOption.allCases, id: \.self) { option in
                    HStack(spacing: 0) {
                        Text(option.rawValue)
                            .font(Square.mono(11))
                            .foregroundStyle(DesignTokens.Colors.ink2)
                            .frame(width: 120, alignment: .leading)
                        ForEach(SquarePose.allCases, id: \.self) { pose in
                            HStack(spacing: 10) {
                                Button("show") {}.buttonStyle(HoverOptionStyle(option: option))
                                Button("stop") {}.buttonStyle(HoverOptionStyle(option: option, primary: true))
                            }
                            .environment(\.squarePose, pose)
                            .frame(width: 150, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

private enum HoverOption: String, CaseIterable {
    case dashes = "dashed edge"
    case wash = "grey wash"
    case fill = "fill"
    case shadow = "hard shadow"
    case thick = "thick edge"
    case underline = "underline"
}

private struct HoverOptionStyle: ButtonStyle {
    let option: HoverOption
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        HoverOptionLabel(configuration: configuration, option: option, primary: primary)
    }
}

private struct HoverOptionLabel: View {
    let configuration: ButtonStyleConfiguration
    let option: HoverOption
    let primary: Bool
    @Environment(\.squarePose) private var pose
    @State private var hovering = false

    private var hot: Bool { pose.hot(hovering) }
    private var down: Bool { pose.down(configuration.isPressed) }
    /// The hard shadow's reach, and how far a held button travels onto it.
    private static let shadowOffset: CGFloat = 2

    var body: some View {
        configuration.label
            .font(Square.mono(Square.controlSize))
            .centredLowercase()
            .underline(option == .underline && hot && !down, color: foreground)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: SquareButtonStyle.height)
            .background(Rectangle().fill(fill))
            .overlay(Rectangle().strokeBorder(edge, style: StrokeStyle(lineWidth: edgeWidth, dash: option == .dashes && hot ? SquareEdge.dash : [])))
            .overlay { if option == .thick, primary, hot, !down { Rectangle().stroke(DesignTokens.Colors.ink, lineWidth: 2).padding(-3) } }
            .offset(x: travel, y: travel)
            .background { if option == .shadow, hot, !down { Rectangle().fill(DesignTokens.Colors.ink).offset(x: Self.shadowOffset, y: Self.shadowOffset) } }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var travel: CGFloat { option == .shadow && down ? Self.shadowOffset : 0 }

    private var foreground: Color {
        if option == .fill, hot || down { return primary ? DesignTokens.Colors.ink : DesignTokens.Colors.onSlab }
        return primary ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink
    }

    private var fill: Color {
        switch option {
        case .dashes, .underline, .thick:
            if primary { return down ? DesignTokens.Colors.inkA64 : DesignTokens.Colors.slab }
            return down ? DesignTokens.Colors.inkA08 : .clear
        case .wash:
            if primary { return down ? DesignTokens.Colors.inkA64 : hot ? DesignTokens.Colors.inkA88 : DesignTokens.Colors.slab }
            return down ? DesignTokens.Colors.inkA12 : hot ? DesignTokens.Colors.inkA08 : .clear
        case .fill:
            if primary { return down ? DesignTokens.Colors.inkA08 : hot ? DesignTokens.Colors.paper : DesignTokens.Colors.slab }
            return down ? DesignTokens.Colors.inkA64 : hot ? DesignTokens.Colors.slab : .clear
        case .shadow:
            return primary ? DesignTokens.Colors.slab : DesignTokens.Colors.paper
        }
    }

    private var edge: Color {
        switch option {
        case .dashes: return primary ? (hot ? DesignTokens.Colors.onSlab : .clear) : DesignTokens.Colors.ink
        case .fill: return primary ? (hot || down ? DesignTokens.Colors.ink : .clear) : DesignTokens.Colors.ink
        default: return primary ? .clear : DesignTokens.Colors.ink
        }
    }

    private var edgeWidth: CGFloat { option == .thick && !primary && hot ? 2 : DesignTokens.hairline }
}

#Preview("button") { SquareButtonSpecimen() }
#Preview("icon button") { SquareIconButtonSpecimen() }
#Preview("button hovers") { SquareButtonHoverSpecimen() }
#endif
