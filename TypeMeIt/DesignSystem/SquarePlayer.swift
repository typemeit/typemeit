import SwiftUI

/// The player's play button: a 34 pt square on the slab.
struct SquarePlayButtonStyle: ButtonStyle {
    static let side: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        SquarePlayButton(configuration: configuration)
    }
}

/// Its fill fades under the pointer like every filled button's.
private struct SquarePlayButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(DesignTokens.Colors.onSlab)
            .frame(width: SquarePlayButtonStyle.side, height: SquarePlayButtonStyle.side)
            .background(SquareButtonStyle.fill(DesignTokens.Colors.slab, hot: hovering, down: configuration.isPressed))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// How far through the audio: ink along an ink-a04 bar. A click or a drag
/// moves it, and the player is told once, when the pointer lifts.
struct SquareScrubber: View {
    let fraction: Double
    let seek: (Double) -> Void
    @State private var dragging: Double?

    private static let height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let shown = min(max(dragging ?? fraction, 0), 1)
            Rectangle()
                .fill(DesignTokens.Colors.inkA04)
                .overlay(alignment: .leading) {
                    Rectangle().fill(DesignTokens.Colors.ink).frame(width: geo.size.width * shown)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragging = min(max($0.location.x / max(geo.size.width, 1), 0), 1) }
                    .onEnded { _ in
                        if let dragging { seek(dragging) }
                        dragging = nil
                    })
        }
        .frame(height: SquareScrubber.height)
        .accessibilityElement()
        .accessibilityLabel("position")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

#if DEBUG
struct SquarePlayerSpecimen: View {
    @State private var fraction = 0.35

    var body: some View {
        SquareSpecimen {
            HStack(spacing: 18) {
                Button {} label: { SquareIcon("akar-play", size: 14) }
                    .buttonStyle(SquarePlayButtonStyle())
                SquareScrubber(fraction: fraction) { fraction = $0 }
            }
            .frame(width: 420)
        }
    }
}
#endif
