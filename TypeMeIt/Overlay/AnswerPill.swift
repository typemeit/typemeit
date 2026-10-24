import AppKit
import SwiftUI

/// A question from a meeting and Claude's answer, as one pill that stays put
/// from offer to answer: the question in the pill's own row, the row's mark
/// turning while Claude works, then the answer under it at once, which the
/// chevron folds away again, also at once.
struct AnswerPill: View {
    enum Stage: Equatable {
        case offered
        /// Asked while another question is being answered; it waits its turn.
        case queued
        case asking
        case answered(ClaudeRun.Answer)
    }

    @Bindable var model: OverlayModel
    let question: String
    let stage: Stage

    static let width: CGFloat = 420
    /// The answer scrolls past this, so the pill never outgrows the panel.
    static let answerMaxHeight: CGFloat = 220
    /// A one-line row is the pill's usual height; a longer question wraps
    /// and the row grows, its mark and buttons centred on it.
    private static let rowHeight: CGFloat = 48
    private static let rowInset = (rowHeight - SquareButtonStyle.height) / 2
    private static let rowLeading: CGFloat = 14
    private static let markSide: CGFloat = 20
    private static let markGap: CGFloat = 12
    private static let questionInset: CGFloat = 6
    /// The answer starts under the question's first letter.
    private static let answerLeading = rowLeading + markSide + markGap + questionInset

    @State private var answerHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            row
            if case .answered(let answer) = stage, model.answerExpanded {
                Rectangle().fill(DesignTokens.Colors.onSlab.opacity(0.16)).frame(height: DesignTokens.hairline)
                answerBody(answer)
            }
        }
        .frame(width: Self.width)
        .background(DesignTokens.Colors.slab)
        .clipped()
        .squareLift()
        .environment(\.squareOnSlab, true)
    }

    private var row: some View {
        HStack(alignment: .center, spacing: Self.markGap) {
            mark.frame(width: Self.markSide, height: SquareButtonStyle.height)
            Text(question)
                .font(Square.mono(13, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.onSlab)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.questionInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                actions
                // An offered question is answered no or ask claude; the cross cancels
                // one being asked and dismisses an answer.
                if stage != .offered {
                    Button { if stage == .asking { model.onCancelAsk?() } else { model.onDismissMeeting?() } } label: {
                        SquareIcon("akar-cross", size: 12)
                    }
                    .buttonStyle(SquareIconButtonStyle())
                    .help(stage == .asking ? "cancel" : "dismiss")
                    .accessibilityLabel(stage == .asking ? "cancel" : "dismiss")
                }
            }
        }
        .padding(.leading, Self.rowLeading)
        .padding(.trailing, 10)
        .padding(.vertical, Self.rowInset)
        .frame(minHeight: Self.rowHeight)
    }

    @ViewBuilder private var mark: some View {
        switch stage {
        case .offered:
            SquareClaudeMark().foregroundStyle(DesignTokens.Colors.onSlab)
        case .queued:
            SquareClaudeMark().foregroundStyle(DesignTokens.Colors.onSlab.opacity(0.4))
        case .asking:
            SquareClaudeSpinner(size: 14).foregroundStyle(DesignTokens.Colors.onSlab)
        case .answered(let answer):
            if answer.failed {
                SquareHatch()
            } else {
                SquareClaudeMark().foregroundStyle(DesignTokens.Colors.onSlab)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch stage {
        case .offered:
            Button("no") { model.onDeclineQuestion?(question) }.buttonStyle(SquareButtonStyle(kind: .quiet))
            Button("ask claude") { model.onAskClaude?(question) }.buttonStyle(SquareButtonStyle(kind: .primary))
        case .queued:
            Text("queued")
                .font(Square.mono(11))
                .foregroundStyle(DesignTokens.Colors.onSlab.opacity(0.6))
                .centredLowercase(size: 11)
        case .asking:
            if model.askOpens {
                Button("open") { model.onOpenAsk?() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .answered(let answer):
            Button { model.answerExpanded.toggle() } label: {
                SquareIcon("akar-chevron-down", size: 12)
                    .rotationEffect(.degrees(model.answerExpanded ? 180 : 0))
            }
            .buttonStyle(SquareIconButtonStyle())
            .help(model.answerExpanded ? "fold answer" : "show answer")
            .accessibilityLabel(model.answerExpanded ? "fold answer" : "show answer")
            if model.askOpens {
                Button("open") { model.onOpenAsk?() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        }
    }

    private func answerBody(_ answer: ClaudeRun.Answer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let color = NSColor(DesignTokens.Colors.onSlab).withAlphaComponent(answer.failed ? 0.7 : 0.92)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(ClaudeReplyPart.parts(of: answer.text).enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .prose(let prose):
                            LinkText(markdown: prose, font: Square.appKitMono(12), color: color, lineSpacing: 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        case .drawing(let drawing):
                            // Scrolls sideways rather than wrap, which would break its lines apart.
                            ScrollView(.horizontal) {
                                Text(drawing).font(Square.mono(12)).foregroundStyle(Color(nsColor: color))
                                    .fixedSize().textSelection(.enabled)
                            }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(answerHeight, Self.answerMaxHeight))
        }
        .padding(.leading, Self.answerLeading)
        .padding(.trailing, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
