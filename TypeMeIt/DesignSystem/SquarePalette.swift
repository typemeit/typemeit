import SwiftUI

/// What colour the cloud is: grey, whatever is behind it, or one of the
/// seven colours. One choice, where the settings today have a switch, a
/// palette and a second switch.
enum CloudChoice: Hashable, Sendable {
    case grey, matchBehind, colour(CloudColor)

    static let all: [CloudChoice] = [.grey, .matchBehind] + CloudColor.allCases.map { .colour($0) }

    var label: String {
        switch self {
        case .grey: "grey"
        case .matchBehind: "match what is behind it"
        case .colour(let c): c.label
        }
    }
}

/// The cloud's palette: every choice a resting puff, spread evenly across
/// the row, the chosen one half as big again and a hovered one a quarter.
/// "Match what is behind it" is the cloud dark on one side and light on the
/// other, the line between them drifting across it. It reads the screen, so
/// choosing it says so under the row with the way to allow it.
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
    /// "Grey" is the plain cloud, drawn in a grey that shows on paper and on
    /// dark.
    static let grey = Color(white: 0.61)
    /// The two sides of "match what is behind it": the cloud on something
    /// light, and on something dark.
    private static let onLight = Color(white: 0.24)
    private static let onDark = Color(white: 0.85)

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
                    .help(choice.label)
                    .accessibilityLabel(choice.label)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            if selection == .matchBehind {
                HStack(spacing: 10) {
                    Text(screenRecordingAllowed ? "reads a few pixels under the cloud" : "reads a few pixels under the cloud · needs screen recording permissions")
                        .font(Square.sans(11.5))
                        .foregroundStyle(DesignTokens.Colors.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !screenRecordingAllowed {
                        Button("system settings", action: openSystemSettings).buttonStyle(SquareButtonStyle(small: true))
                    }
                }
            }
        }
    }

    @ViewBuilder private func swatch(_ choice: CloudChoice, index: Int) -> some View {
        switch choice {
        case .matchBehind:
            puff(SquareCloudPalette.onLight, index: index, splitTint: SquareCloudPalette.onDark)
        case .grey:
            puff(SquareCloudPalette.grey, index: index)
        case .colour(let c):
            puff(Color(nsColor: c.color), index: index)
        }
    }

    private func puff(_ tint: Color, index: Int, splitTint: Color? = nil) -> some View {
        PuffView(level: 0, tint: tint, timeOffset: Double(index) * PuffView.neighbourTimeOffset, splitTint: splitTint)
            .frame(width: PuffView.drawnSide(filling: SquareCloudPalette.cell * SquareCloudPalette.fill),
                   height: PuffView.drawnSide(filling: SquareCloudPalette.cell * SquareCloudPalette.fill))
            .frame(width: SquareCloudPalette.cell, height: SquareCloudPalette.cell)
    }
}

#if DEBUG
struct SquareCloudPaletteSpecimen: View {
    @State private var choice = CloudChoice.colour(.sky)
    @State private var match = CloudChoice.matchBehind

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "a colour") { SquareCloudPalette(selection: $choice).frame(width: 720) }
            SquareSpecimenLine(name: "match behind") { SquareCloudPalette(selection: $match).frame(width: 720) }
        }
    }
}

#Preview("cloud palette") { SquareCloudPaletteSpecimen() }
#endif
