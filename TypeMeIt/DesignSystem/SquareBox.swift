import SwiftUI

/// Figures in an ink-bordered box, with a mono title above it.
struct SquareBox<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(DesignTokens.Fonts.label.weight(.regular).monospaced())
                    .foregroundStyle(DesignTokens.Colors.ink2)
            }
            VStack(spacing: 0) { content }
                .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
        }
    }
}

/// One figure in its own box: what it counts, the number, a caption, and
/// anything drawn under them, such as a gauge. Fills the height of its row.
struct SquareStat<Below: View>: View {
    let label: String
    let value: String
    let caption: String
    @ViewBuilder var below: Below

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink2)
            Text(value).font(Square.mono(26, weight: .medium))
            Text(caption).font(Square.sans(11)).foregroundStyle(DesignTokens.Colors.ink2)
            below
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
    }
}

extension SquareStat where Below == EmptyView {
    init(label: String, value: String, caption: String) {
        self.init(label: label, value: value, caption: caption) { EmptyView() }
    }
}

#if DEBUG
struct SquareBoxSpecimen: View {
    var body: some View {
        SquareSpecimen {
            SquareBox(title: "speed") {
                HStack { Text("speech"); Spacer(); Text("170 ms").font(Square.mono(12)) }
                    .font(Square.sans(12)).padding(.horizontal, 14).padding(.vertical, 10)
                SquareRule(color: DesignTokens.Colors.inkA20)
                HStack { Text("apple intelligence"); Spacer(); Text("630 ms").font(Square.mono(12)) }
                    .font(Square.sans(12)).padding(.horizontal, 14).padding(.vertical, 10)
            }
            .frame(width: 320)
        }
    }
}

struct SquareStatSpecimen: View {
    var body: some View {
        SquareSpecimen {
            HStack(alignment: .top, spacing: 12) {
                SquareStat(label: "words dictated", value: "12,480", caption: "1,206 dictations")
                SquareStat(label: "words per minute", value: "96", caption: "2.4× faster than typing") {
                    Rectangle().fill(DesignTokens.Colors.ink).frame(height: 6).padding(.top, 8)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 440)
        }
    }
}
#endif
