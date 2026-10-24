import SwiftUI

/// What colour the cloud is: dynamic, black, white, or one of the seven
/// hues. A dynamic cloud goes black or white against what is behind it, and
/// follows light and dark mode until Screen Recording lets it look.
enum CloudChoice: Hashable, Sendable {
    case dynamic, colour(CloudColor)

    static let all: [CloudChoice] = [.dynamic] + CloudColor.neutrals.map { .colour($0) } + CloudColor.hues.map { .colour($0) }

    var label: String {
        switch self {
        case .dynamic: "dynamic"
        case .colour(let c): c.label
        }
    }
}

/// The cloud's palette: every choice a resting puff, spread evenly across
/// the row, the chosen one half as big again and a hovered one a quarter.
/// Dynamic is the cloud dark on one side and light on the other, the line
/// between them drifting across it. Under the row, the cloud under the
/// pointer, or else the chosen one: a colour's name, or what dynamic reads
/// and, until it may, the way to allow it.
struct SquareCloudPalette: View {
    @Binding var selection: CloudChoice
    var screenRecordingAllowed = false
    var openSystemSettings: () -> Void = {}
    @State private var hovered: CloudChoice?

    private static let cell: CGFloat = 64
    /// When the row is narrow the cells give up their margins, down to this.
    private static let narrowest: CGFloat = 40
    /// Each puff is drawn for a cell this much bigger than its own, so a
    /// resting cloud fills most of the cell and the chosen one, half as big
    /// again, still just fits.
    private static let fill: CGFloat = 1.25
    /// Black and white as the palette draws them, a little off so that each
    /// still shows on paper of its own colour.
    private static let onLight = Color(white: 0.24)
    private static let onDark = Color(white: 0.85)
    /// The clouds breathe and drift over seconds, so 20 fps is smooth enough.
    private static let driftInterval = 1.0 / 20

    /// A colour as a page draws its cloud: the hue itself, or black and white
    /// as the palette draws them.
    static func tint(_ colour: CloudColor) -> Color {
        switch colour {
        case .black: onLight
        case .white: onDark
        default: Color(nsColor: colour.color)
        }
    }

    /// The cloud a page shows for `choice`; for dynamic, whichever of black
    /// and white stands out on the page.
    static func tint(_ choice: CloudChoice, scheme: ColorScheme) -> Color {
        switch choice {
        case .dynamic: tint(scheme == .dark ? .white : .black)
        case .colour(let c): tint(c)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Array(CloudChoice.all.enumerated()), id: \.element) { i, choice in
                    if i > 0 { Spacer(minLength: 0) }
                    let on = choice == selection
                    let scale = on ? 1.5 : (hovered == choice ? 1.25 : 1.0)
                    Button { selection = choice } label: {
                        swatch(choice, index: i)
                            .scaleEffect(scale)
                            .animation(.easeOut(duration: DesignTokens.Duration.n2), value: scale)
                            .frame(width: SquareCloudPalette.cell, height: SquareCloudPalette.cell)
                            .frame(minWidth: SquareCloudPalette.narrowest, maxWidth: SquareCloudPalette.cell)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? choice : (hovered == choice ? nil : hovered) }
                    .accessibilityLabel(choice.label)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            let described = hovered ?? selection
            HStack(spacing: 10) {
                Text(SquareCloudPalette.caption(described))
                    .font(Square.sans(11.5))
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selection == .dynamic && !screenRecordingAllowed {
                    // Kept in place under another cloud's name, so the row
                    // holds still as the pointer crosses the palette.
                    Button("system settings", action: openSystemSettings)
                        .buttonStyle(SquareButtonStyle(small: true))
                        .opacity(described == .dynamic ? 1 : 0)
                }
            }
        }
    }

    /// What the row under the palette says for a choice.
    private static func caption(_ choice: CloudChoice) -> String {
        switch choice {
        case .dynamic: "picks black or white from the pixels under it (requires screen recording permissions)"
        case .colour(let c): c.label
        }
    }

    @ViewBuilder private func swatch(_ choice: CloudChoice, index: Int) -> some View {
        switch choice {
        case .dynamic:
            puff(SquareCloudPalette.tint(.black), index: index, splitTint: SquareCloudPalette.tint(.white))
        case .colour(let c):
            puff(SquareCloudPalette.tint(c), index: index)
        }
    }

    private func puff(_ tint: Color, index: Int, splitTint: Color? = nil) -> some View {
        // Drawn as often as a slow drift needs: ten clouds at the overlay's
        // 60 fps kept the processor busy.
        PuffView(level: 0, tint: tint, timeOffset: Double(index) * PuffView.neighbourTimeOffset,
                 frameInterval: SquareCloudPalette.driftInterval, splitTint: splitTint)
            .frame(width: PuffView.drawnSide(filling: SquareCloudPalette.cell * SquareCloudPalette.fill),
                   height: PuffView.drawnSide(filling: SquareCloudPalette.cell * SquareCloudPalette.fill))
            .frame(width: SquareCloudPalette.cell, height: SquareCloudPalette.cell)
    }
}

#if DEBUG
struct SquareCloudPaletteSpecimen: View {
    @State private var choice = CloudChoice.colour(.sky)
    @State private var match = CloudChoice.dynamic

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "a colour") { SquareCloudPalette(selection: $choice).frame(width: 720) }
            SquareSpecimenLine(name: "dynamic") { SquareCloudPalette(selection: $match).frame(width: 720) }
        }
    }
}

#Preview("cloud palette") { SquareCloudPaletteSpecimen() }
#endif
