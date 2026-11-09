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
        .squareLift(overApps: true)
        .environment(\.squareOnSlab, true)
    }

    private var row: some View {
        HStack(alignment: .center, spacing: Self.markGap) {
            mark.frame(width: Self.markSide, height: SquareButtonStyle.height)
            questionText
                .font(Square.mono(13, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.onSlab)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.questionInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                actions
                // The cross declines an offered question, cancels one being
                // asked and dismisses an answer.
                Button(action: cross) { SquareIcon("akar-cross", size: 12) }
                    .buttonStyle(SquareDismissStyle())
                    .help(crossHelp)
                    .accessibilityLabel(crossHelp)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, Self.rowLeading)
        .padding(.trailing, 10)
        .padding(.vertical, Self.rowInset)
        .frame(minHeight: Self.rowHeight)
    }

    /// An offered question can be edited before it is asked; Return asks it.
    @ViewBuilder private var questionText: some View {
        if stage == .offered {
            TextField("", text: Binding(get: { model.questionDraft ?? question }, set: { model.questionDraft = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .tint(DesignTokens.Colors.onSlab)
                .onSubmit(ask)
        } else {
            Text(question)
        }
    }

    private func ask() {
        model.onAskClaude?(model.questionDraft ?? question)
    }

    private var crossHelp: String {
        switch stage {
        case .offered: "no"
        case .asking: "cancel"
        case .queued, .answered: "dismiss"
        }
    }

    private func cross() {
        switch stage {
        case .offered: model.onDeclineQuestion?(question)
        case .asking: model.onCancelAsk?()
        case .queued, .answered: model.onDismissMeeting?()
        }
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
            if model.offerCopies {
                SquarePromptIcon(icon: "akar-copy", help: "copy", kind: .quiet) { model.onCopyDictation?() }
            }
            Button("ask claude", action: ask).buttonStyle(SquareButtonStyle(kind: .primary))
        case .queued:
            Text("queued")
                .font(Square.mono(11))
                .foregroundStyle(DesignTokens.Colors.onSlab.opacity(0.6))
                .centredLowercase(size: 11)
        case .asking:
            if model.askOpens {
                openButton
            }
        case .answered(let answer):
            Button { model.answerExpanded.toggle() } label: {
                SquareIcon("akar-chevron-down", size: 12)
                    .rotationEffect(.degrees(model.answerExpanded ? 180 : 0))
            }
            .buttonStyle(SquareDismissStyle())
            .help(model.answerExpanded ? "fold answer" : "show answer")
            .accessibilityLabel(model.answerExpanded ? "fold answer" : "show answer")
            if let sessionID = answer.sessionID, ClaudeDesktop.installed {
                SquareClaudeButton(title: "continue in claude", iconOnly: true) { model.onContinueInClaude?(sessionID) }
            }
            if model.askOpens {
                openButton
            }
        }
    }

    private var openButton: some View {
        Button { model.onOpenAsk?() } label: { SquareIcon("akar-link-out", size: 12) }
            .buttonStyle(SquareDismissStyle())
            .help("open")
            .accessibilityLabel("open")
    }

    private func answerBody(_ answer: ClaudeRun.Answer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                ClaudeMarkdown(reply: answer.text, font: Square.mono(12), colour: DesignTokens.Colors.onSlab.opacity(answer.failed ? 0.7 : 0.92))
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
}
