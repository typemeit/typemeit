import SwiftUI

/// The prompt grown open into a list to pick from: its mark and question on
/// top, one line per choice under it, and a click on a line answers. The
/// cross answers none.
struct SquareChoicePrompt: View {
    let icon: String
    let question: String
    let choices: [String]
    /// What a click on a line does, shown on the line under the pointer.
    let verb: String
    let dismiss: String
    var onDismiss: () -> Void
    var onPick: (Int) -> Void

    private let fg = DesignTokens.Colors.onSlab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SquareIcon(icon, size: 14).foregroundStyle(fg)
                Text(question).font(Square.mono(13)).foregroundStyle(fg).lineLimit(1).centredLetters(question, size: 13)
                Spacer()
                Button(action: onDismiss) { SquareIcon("akar-cross", size: 12) }
                    .buttonStyle(SquareDismissStyle())
                    .help(dismiss)
                    .accessibilityLabel(dismiss)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: 48)
            .overlay(alignment: .bottom) { SquareRule(color: SquareEdge.slabRule) }
            VStack(spacing: 0) {
                ForEach(Array(choices.enumerated()), id: \.offset) { position, choice in
                    SquareChoiceRow(number: position + 1, text: choice, verb: verb, fg: fg) { onPick(position) }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: SquareHookTray.width)
        .background(DesignTokens.Colors.slab)
        .squareLift(overApps: true)
        .environment(\.squareOnSlab, true)
    }
}

private struct SquareChoiceRow: View {
    let number: Int
    let text: String
    let verb: String
    let fg: Color
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                SquareRunNumber(number: number, colour: fg.opacity(0.45)).frame(width: SquareHookTray.numberWidth, alignment: .leading)
                Text(text).font(Square.mono(13)).foregroundStyle(fg)
                    .lineLimit(1).truncationMode(.middle).centredLetters(text, size: 13)
                Spacer()
                if hovering {
                    Text(verb).font(Square.mono(11)).foregroundStyle(fg.opacity(0.6)).centredLetters(verb, size: 11)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: SquareHookTray.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SquareSlabLineStyle(hot: hovering))
        .onHover { hovering = $0 }
        .accessibilityLabel("\(verb) \(text)")
    }
}
