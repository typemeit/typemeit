import SwiftUI

/// Claude's answer as the type me it camera shows it: the pill's slab, the
/// question in mono, and the answer's first paragraph large enough to read
/// in a meeting's small tile. The whole answer is in the pill on screen.
/// Fixed colours: the frame goes out to everyone, whatever this Mac's appearance.
struct CameraAnswerCard: View {
    let question: String
    let answer: String

    static let width: CGFloat = 1040
    /// A longer answer is set smaller, so the card stays inside the frame:
    /// each size up to its count of characters, then the smallest, cut at
    /// this many lines.
    static let answerSizes: [(characters: Int, size: CGFloat)] = [(120, 40), (200, 34), (300, 28)]
    static let answerSmallest: CGFloat = 24
    static let answerMaxLines = 9
    private static let slab = Color(.sRGB, red: 0.0392, green: 0.0392, blue: 0.0392, opacity: 0.94)
    private static let onSlab = Color.white

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                // The puff fills about a third of its frame.
                PuffView(expansion: 0.9, frozenTime: 100)
                    .frame(width: 120, height: 120)
                    .padding(-34)
                Text(question)
                    .font(Square.mono(24))
                    .foregroundStyle(Self.onSlab.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 20)
            Rectangle().fill(Self.onSlab.opacity(0.16)).frame(height: 1)
            let lead = Self.lead(of: answer)
            Text((try? AttributedString(markdown: lead, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(lead))
                .font(.system(size: Self.answerSize(for: lead), weight: .medium))
                .lineSpacing(8)
                .foregroundStyle(Self.onSlab)
                .lineLimit(Self.answerMaxLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 36)
                .padding(.vertical, 30)
        }
        .frame(width: Self.width, alignment: .leading)
        .background(Self.slab)
    }

    /// The answer's first paragraph: Claude leads with the answer and says
    /// where it came from after.
    static func lead(of answer: String) -> String {
        answer.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? answer
    }

    static func answerSize(for lead: String) -> CGFloat {
        answerSizes.first { lead.count <= $0.characters }?.size ?? answerSmallest
    }

    @MainActor static func image(question: String, answer: String) -> CGImage? {
        let renderer = ImageRenderer(content: CameraAnswerCard(question: question, answer: answer))
        renderer.scale = 1
        return renderer.cgImage
    }
}
