import SwiftUI
import Textual

/// Claude's reply rendered as Markdown: paragraphs, lists, headings, tables
/// and code blocks, in one colour on hairline rules. Tables Claude drew in
/// ASCII render as tables (`ClaudeReplyMarkdown`); a code block, where its
/// other drawings go, is set in mono and scrolls sideways rather than wrap.
struct ClaudeMarkdown: View {
    let reply: String
    let font: Font
    let colour: Color
    /// Code, inline and in blocks, is mono at this size.
    var codeSize: CGFloat = 12

    var body: some View {
        StructuredText(markdown: ClaudeReplyMarkdown.markdown(reply))
            .font(font)
            .foregroundStyle(colour)
            .textual.structuredTextStyle(ClaudeMarkdownStyle(codeSize: codeSize, colour: colour))
            .textual.highlighterTheme(.init(foregroundColor: DynamicColor(colour), backgroundColor: DynamicColor(.clear)))
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ClaudeMarkdownStyle: StructuredText.Style {
    let codeSize: CGFloat
    let colour: Color
    private var rule: Color { colour.opacity(0.24) }

    var inlineStyle: InlineStyle {
        InlineStyle()
            .code(.font(Square.mono(codeSize)))
            .strong(.fontWeight(.semibold))
            // Links keep the text's colour, marked by the underline alone.
            .link(.foregroundColor(DynamicColor(colour)), .underlineStyle(.single))
    }
    var headingStyle: ClaudeHeadingStyle { ClaudeHeadingStyle() }
    var paragraphStyle: ClaudeParagraphStyle { ClaudeParagraphStyle() }
    var blockQuoteStyle: ClaudeBlockQuoteStyle { ClaudeBlockQuoteStyle(rule: rule) }
    var codeBlockStyle: ClaudeCodeBlockStyle { ClaudeCodeBlockStyle(size: codeSize) }
    var listItemStyle: StructuredText.DefaultListItemStyle { .default }
    var unorderedListMarker: StructuredText.SymbolListMarker { .disc }
    var orderedListMarker: StructuredText.DecimalListMarker { .decimal }
    var tableStyle: ClaudeTableStyle { ClaudeTableStyle(rule: rule) }
    var tableCellStyle: ClaudeTableCellStyle { ClaudeTableCellStyle() }
    var thematicBreakStyle: ClaudeThematicBreakStyle { ClaudeThematicBreakStyle(rule: rule) }
}

/// The reply sits in a small panel, so headings stay near the body's size.
private struct ClaudeHeadingStyle: StructuredText.HeadingStyle {
    private static let largeScale: CGFloat = 1.15

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.fontScale(configuration.headingLevel <= 2 ? Self.largeScale : 1)
            .fontWeight(.semibold)
            .textual.blockSpacing(.fontScaled(top: 1.2, bottom: 0.4))
    }
}

private struct ClaudeParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .textual.lineSpacing(.fontScaled(0.35))
            .textual.blockSpacing(.fontScaled(top: 0.8))
    }
}

private struct ClaudeBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    let rule: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(rule).frame(width: 2)
            configuration.label.opacity(0.8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .textual.blockSpacing(.fontScaled(top: 0.8))
    }
}

private struct ClaudeCodeBlockStyle: StructuredText.CodeBlockStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Overflow {
            configuration.label
                .font(Square.mono(size))
                .textual.lineSpacing(.fontScaled(0.2))
                .fixedSize(horizontal: false, vertical: true)
        }
        .textual.blockSpacing(.fontScaled(top: 0.8))
    }
}

private struct ClaudeTableStyle: StructuredText.TableStyle {
    let rule: Color

    func makeBody(configuration: Configuration) -> some View {
        Overflow {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .textual.tableOverlay { layout in
                    Canvas { context, _ in
                        for divider in layout.dividers() { context.fill(Path(divider), with: .color(rule)) }
                    }
                }
                .padding(DesignTokens.hairline)
                .overlay(Rectangle().strokeBorder(rule, lineWidth: DesignTokens.hairline))
        }
        .textual.tableCellSpacing(horizontal: DesignTokens.hairline, vertical: DesignTokens.hairline)
        .textual.blockSpacing(.fontScaled(top: 0.8))
    }
}

private struct ClaudeTableCellStyle: StructuredText.TableCellStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(configuration.row == 0 ? .semibold : .regular)
            .textual.lineSpacing(.fontScaled(0.2))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
    }
}

private struct ClaudeThematicBreakStyle: StructuredText.ThematicBreakStyle {
    let rule: Color

    func makeBody(configuration: Configuration) -> some View {
        Rectangle().fill(rule).frame(height: DesignTokens.hairline)
            .textual.blockSpacing(.fontScaled(top: 1, bottom: 1))
    }
}
