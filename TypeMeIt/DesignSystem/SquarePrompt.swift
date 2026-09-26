import SwiftUI

/// The prompt: the square pill the app floats over everything after a
/// dictation, when an update is ready, or when a call starts. Its mark, the
/// message in mono left-aligned after it, and its buttons and cross on the
/// right. A failure inverts to the slab, so it never reads as a success.
struct SquarePrompt<Actions: View>: View {
    enum Mark {
        case none
        /// An akar icon.
        case icon(String)
        /// The first letter of the app a call is in.
        case app(String)
        /// An akar icon that is also a way somewhere, such as the
        /// dictionary a learned word went to.
        case button(String, help: String, action: () -> Void)
    }

    var mark: Mark = .none
    let message: Text
    var failed = false
    /// The cross's tooltip; without one there is no cross.
    var dismiss: String?
    var onDismiss: () -> Void = {}
    var minWidth: CGFloat?
    @ViewBuilder var actions: Actions

    /// The pointer's square round a mark that is a button.
    fileprivate static var markButton: CGFloat { 22 }

    var body: some View {
        HStack(spacing: 12) {
            markView
            message
                .font(Square.mono(Square.controlSize))
                .foregroundStyle(failed ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .centredLowercase()
            Spacer(minLength: 14)
            HStack(spacing: 4) {
                actions
                if let dismiss {
                    Button(action: onDismiss) { SquareIcon("akar-cross", size: 10) }
                        .buttonStyle(SquareIconButtonStyle())
                        .help(dismiss)
                        .accessibilityLabel(dismiss)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .frame(minWidth: minWidth)
        .frame(height: 44)
        .fixedSize(horizontal: minWidth == nil, vertical: false)
        .background(failed ? DesignTokens.Colors.slab : DesignTokens.Colors.paper)
        .overlay(Rectangle().strokeBorder(failed ? DesignTokens.Colors.slab : DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
        .squareLift()
        .environment(\.squareOnSlab, failed)
    }

    @ViewBuilder private var markView: some View {
        let ink = failed ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink
        switch mark {
        case .none:
            Color.clear.frame(width: 14, height: 14)
        case .icon(let name):
            SquareIcon(name, size: 14).foregroundStyle(failed ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink2)
        case .app(let letter):
            Text(letter)
                .font(Square.mono(10))
                .foregroundStyle(ink)
                .centredLetters(letter, size: 10)
                .frame(width: 18, height: 18)
                .overlay(Rectangle().strokeBorder(ink, lineWidth: DesignTokens.hairline))
        case .button(let name, let help, let action):
            // The icon button's grey square reaches past the mark's 14 pt,
            // but the message starts where it would after any other mark.
            Button(action: action) { SquareIcon(name, size: 14) }
                .buttonStyle(SquareIconButtonStyle(side: SquarePrompt.markButton))
                .padding(-(SquarePrompt.markButton - 14) / 2)
                .help(help)
                .accessibilityLabel(help)
        }
    }
}

#if DEBUG
/// Every message the app's pill shows, grouped as on the canvas.
struct SquarePromptSpecimen: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sheet(.light, desk: Color(white: 0.925))
            sheet(.dark, desk: Color(white: 0.086))
        }
        .fixedSize()
    }

    private func sheet(_ scheme: ColorScheme, desk: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            group("dictation")
            SquarePrompt(mark: .icon("akar-clipboard"), message: Text("accessibility is off, so it can't type"), dismiss: "cancel") {
                Button("system settings") {}.buttonStyle(SquareButtonStyle())
                Button("copy transcript") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-clipboard"), message: Text("nowhere to type it"), dismiss: "cancel") {
                Button("copy transcript") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-clipboard"), message: Text("nowhere to type it"), dismiss: "cancel") {
                Button("copied") {}.buttonStyle(SquareButtonStyle(kind: .primary)).disabled(true)
            }
            SquarePrompt(mark: .button("akar-sparkles", help: "open dictionary") {}, message: Text("added \(Text("typeme.it").fontWeight(.medium)) to dictionary"), dismiss: "dismiss") {
                Button("undo") {}.buttonStyle(SquareButtonStyle())
            }
            SquarePrompt(mark: .button("akar-sparkles", help: "open dictionary") {}, message: Text("learned \(counted(3, "word"))"), dismiss: "dismiss") {
                Button("undo") {}.buttonStyle(SquareButtonStyle())
            }
            SquarePrompt(message: Text("undone")) {}
            group("updates")
            SquarePrompt(mark: .icon("akar-sparkles"), message: Text("version \(Text("1.0.1").fontWeight(.medium)) is ready"), dismiss: "later") {
                Button("install") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-sparkles"), message: Text("version 1.0.1 didn't download"), failed: true, dismiss: "dismiss") {}
            group("meetings")
            SquarePrompt(mark: .app("s"), message: Text("record this meeting?"), dismiss: "not now") {
                Button("record") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .app("s"), message: Text("recording again · slack"), dismiss: "dismiss") {
                Button("stop") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("meeting saved"), dismiss: "dismiss") {
                Button("show") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("meeting not transcribed"), failed: true, dismiss: "dismiss") {
                Button("show") {}.buttonStyle(SquareButtonStyle())
            }
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("disk full · meeting stopped"), failed: true, dismiss: "dismiss") {
                Button("show") {}.buttonStyle(SquareButtonStyle())
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 36)
        .background(desk)
        .environment(\.colorScheme, scheme)
    }

    private func group(_ name: String) -> some View {
        Text(name).font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3).padding(.top, 4)
    }
}

#Preview("prompt") { SquarePromptSpecimen() }
#endif
