import SwiftUI

/// Wraps its children onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    /// Each subview's own size, measured once and kept until the subviews
    /// change: a layout pass asks for sizes several times, and a long
    /// dictation is a few hundred words.
    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for size in cache {
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for (s, size) in zip(subviews, cache) {
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Equal columns side by side, top-aligned, while each child fits its column
/// at its ideal width; one above the other, full width, once one does not.
struct ColumnsOrStack: Layout {
    var spacing: CGFloat = 12

    private func sideBySide(_ width: CGFloat?, _ subviews: Subviews) -> Bool {
        guard let width, !subviews.isEmpty else { return true }
        let each = column(width, subviews.count)
        return subviews.allSatisfy { $0.sizeThatFits(.unspecified).width <= each }
    }

    private func column(_ width: CGFloat, _ count: Int) -> CGFloat {
        (width - spacing * CGFloat(count - 1)) / CGFloat(count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            return CGSize(width: sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1)),
                          height: sizes.map(\.height).max() ?? 0)
        }
        if sideBySide(width, subviews) {
            let each = ProposedViewSize(width: column(width, subviews.count), height: nil)
            return CGSize(width: width, height: subviews.map { $0.sizeThatFits(each).height }.max() ?? 0)
        }
        let full = ProposedViewSize(width: width, height: nil)
        let heights = subviews.map { $0.sizeThatFits(full).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if sideBySide(bounds.width, subviews) {
            let each = ProposedViewSize(width: column(bounds.width, subviews.count), height: nil)
            var x = bounds.minX
            for s in subviews {
                s.place(at: CGPoint(x: x, y: bounds.minY), proposal: each)
                x += column(bounds.width, subviews.count) + spacing
            }
        } else {
            let full = ProposedViewSize(width: bounds.width, height: nil)
            var y = bounds.minY
            for s in subviews {
                s.place(at: CGPoint(x: bounds.minX, y: y), proposal: full)
                y += s.sizeThatFits(full).height + spacing
            }
        }
    }
}

#if DEBUG
struct SquareLayoutsSpecimen: View {
    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "flow") {
                FlowLayout(spacing: 6) {
                    ForEach(["kubernetes", "postgres", "inngest", "twilio", "parakeet", "fluidaudio", "nemotron"], id: \.self) { word in
                        Text(word).font(Square.mono(12)).padding(.horizontal, 8).padding(.vertical, 4)
                            .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
                    }
                }
                .frame(width: 260)
            }
            SquareSpecimenLine(name: "columns") {
                ColumnsOrStack {
                    SquareBox(title: "length") { Text("speech · 4.8 s").font(Square.mono(12)).padding(10) }
                    SquareBox(title: "speed") { Text("speech · 170 ms").font(Square.mono(12)).padding(10) }
                }
                .frame(width: 420)
            }
        }
    }
}
#endif
