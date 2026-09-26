import SwiftUI

/// The design system's button: mono label, ink outline, inverts when primary,
/// loses its outline when quiet. Disabled drops to ink-3 on a rule border.
///
/// The pointer states are the ones `web/styles/app.css` gives `.btn-*`: an
/// outlined button takes an ink-a04 wash and a primary one eases off its slab
/// to ink-a88, and both go a step further while held. A disabled button
/// answers neither.
struct InkButtonStyle: ButtonStyle {
    var primary = false
    var quiet = false
    func makeBody(configuration: Configuration) -> some View {
        InkButtonLabel(configuration: configuration, primary: primary, quiet: quiet)
    }

    private struct InkButtonLabel: View {
        let configuration: Configuration
        let primary: Bool
        let quiet: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        private var hot: Bool { hovering && enabled }

        var body: some View {
            configuration.label
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm).fill(background))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm).strokeBorder(border, lineWidth: DesignTokens.hairline))
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: DesignTokens.Duration.n1), value: hot)
        }

        private var foreground: Color {
            if !enabled { return DesignTokens.Colors.ink3 }
            if primary { return DesignTokens.Colors.onSlab }
            if quiet { return hot ? DesignTokens.Colors.ink : DesignTokens.Colors.ink2 }
            return DesignTokens.Colors.ink
        }

        private var background: Color {
            if primary {
                guard enabled else { return DesignTokens.Colors.inkA12 }
                if configuration.isPressed { return DesignTokens.Colors.inkA64 }
                return hot ? DesignTokens.Colors.inkA88 : DesignTokens.Colors.slab
            }
            guard enabled else { return .clear }
            if configuration.isPressed { return DesignTokens.Colors.inkA08 }
            return hot ? DesignTokens.Colors.inkA04 : .clear
        }

        private var border: Color {
            if primary || quiet { return .clear }
            return enabled ? DesignTokens.Colors.ink : DesignTokens.Colors.rule
        }
    }
}

/// The design system's plain button: no outline and no fill of its own, an
/// ink-a04 wash and full-strength ink under the pointer, a step darker while
/// held. It is what `.btn-quiet` is on the web, and it is the style for every
/// button that draws its own label — the icon buttons, the sidebar tabs, the
/// crosses that dismiss things.
struct QuietButtonStyle: ButtonStyle {
    /// A square target for icon buttons, so a 10pt glyph still gets something
    /// worth hovering. Nil leaves the label at the size it drew itself.
    var side: CGFloat?
    var radius: CGFloat = DesignTokens.Radius.sm
    /// A selected button is inverted outright and stops answering the pointer,
    /// being already the thing a click would ask for.
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonLabel(configuration: configuration, side: side, radius: radius, selected: selected)
    }

    private struct QuietButtonLabel: View {
        let configuration: Configuration
        let side: CGFloat?
        let radius: CGFloat
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        private var hot: Bool { hovering && enabled && !selected }

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: radius).fill(background))
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: DesignTokens.Duration.n1), value: hot)
        }

        private var foreground: Color {
            if selected { return DesignTokens.Colors.onSlab }
            if !enabled { return DesignTokens.Colors.ink3 }
            return hot ? DesignTokens.Colors.ink : DesignTokens.Colors.ink2
        }

        private var background: Color {
            if selected { return DesignTokens.Colors.slab }
            guard enabled else { return .clear }
            if configuration.isPressed { return DesignTokens.Colors.inkA08 }
            return hot ? DesignTokens.Colors.inkA04 : .clear
        }
    }
}

/// A square inset list with an ink border and a mono title above it.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.lowercased())
                    .font(DesignTokens.Fonts.label.weight(.regular).monospaced())
                    .foregroundStyle(DesignTokens.Colors.ink2)
            }
            VStack(spacing: 0) { content }
                .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
        }
    }
}

/// Full-width hairline between rows.
struct RowRule: View {
    var body: some View { Rectangle().fill(DesignTokens.Colors.inkA20).frame(height: DesignTokens.hairline) }
}

/// A question mark after a row's label. A click pops its explanation up.
struct HelpMark: View {
    let text: String
    @State private var open = false

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(open ? DesignTokens.Colors.ink : DesignTokens.Colors.ink3)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
    }
}

extension SettingsRow {
    /// Parses a label or subtitle as markdown; a malformed string falls back
    /// to a plain AttributedString.
    static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

struct SettingsRow<Control: View>: View {
    var label: String
    var subtitle: String?
    var last = false
    /// A label that holds a link, in place of the plain string.
    var labelView: AnyView?
    /// Links under the label; the plain `subtitle` is a tooltip instead.
    var subtitleView: AnyView?
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Group {
                            if let labelView { labelView } else { Text(SettingsRow.attributed(label)) }
                        }
                        .font(DesignTokens.Fonts.ui.monospaced())
                        if let subtitle { HelpMark(text: subtitle) }
                    }
                    if let subtitleView {
                        subtitleView
                            .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink2).frame(maxWidth: 400, alignment: .leading)
                    }
                }
                Spacer()
                control
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if !last { RowRule() }
        }
    }
}

/// Wraps its children onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
