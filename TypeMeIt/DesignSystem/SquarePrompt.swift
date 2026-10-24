import SwiftUI

/// The prompt: the slab the app floats over everything after a dictation,
/// when an update is ready, or when a call starts. Its mark, the message in
/// mono centred after it, and its buttons and cross on the right. A failure
/// trades its mark for a hatched square, so it never reads as a success.
struct SquarePrompt<Actions: View>: View {
    enum Mark {
        case none
        /// An akar icon.
        case icon(String)
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
    /// The square a failure shows in place of its mark.
    fileprivate static var hatchSide: CGFloat { 20 }

    var body: some View {
        HStack(spacing: 12) {
            markView
            message
                .font(Square.mono(13))
                .foregroundStyle(DesignTokens.Colors.onSlab)
                .lineLimit(1)
                .truncationMode(.middle)
                .centredLowercase()
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                actions
                if let dismiss {
                    Button(action: onDismiss) { SquareIcon("akar-cross", size: 12) }
                        .buttonStyle(SquareDismissStyle())
                        .help(dismiss)
                        .accessibilityLabel(dismiss)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(minWidth: minWidth)
        .frame(height: 48)
        .fixedSize(horizontal: minWidth == nil, vertical: false)
        .background(DesignTokens.Colors.slab)
        .squareLift()
        .environment(\.squareOnSlab, true)
    }

    @ViewBuilder private var markView: some View {
        if failed {
            SquareHatch()
                .frame(width: SquarePrompt.hatchSide, height: SquarePrompt.hatchSide)
        } else {
            plainMark
        }
    }

    @ViewBuilder private var plainMark: some View {
        switch mark {
        case .none:
            Color.clear.frame(width: 14, height: 14)
        case .icon(let name):
            SquareIcon(name, size: 14).foregroundStyle(DesignTokens.Colors.onSlab)
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

/// The cross: on-slab on a faint on-slab square, stronger under the
/// pointer and when held.
private struct SquareDismissStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SquareDismissBody(configuration: configuration)
    }
}

private struct SquareDismissBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.squarePose) private var pose
    @State private var hovering = false

    var body: some View {
        let wash = pose.down(configuration.isPressed) ? 0.32 : pose.hot(hovering) ? 0.24 : 0.16
        configuration.label
            .foregroundStyle(DesignTokens.Colors.onSlab)
            .frame(width: SquareButtonStyle.height, height: SquareButtonStyle.height)
            .background(Rectangle().fill(DesignTokens.Colors.onSlab.opacity(wash)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A failure's mark: an on-slab hairline square hatched corner to corner.
struct SquareHatch: View {
    /// The distance between the hatch's lines.
    private static let pitch: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            var lines = Path()
            var offset: CGFloat = -size.height
            while offset < size.width {
                lines.move(to: CGPoint(x: offset, y: size.height))
                lines.addLine(to: CGPoint(x: offset + size.height, y: 0))
                offset += SquareHatch.pitch
            }
            context.stroke(lines, with: .color(DesignTokens.Colors.onSlab), lineWidth: 1.5)
        }
        .clipped()
        .overlay(Rectangle().strokeBorder(DesignTokens.Colors.onSlab, lineWidth: DesignTokens.hairline))
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
                Button("system settings") {}.buttonStyle(SquareButtonStyle(kind: .quiet))
                Button("copy") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-clipboard"), message: Text("nowhere to type it"), dismiss: "cancel") {
                Button("copy") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-clipboard"), message: Text("nowhere to type it"), dismiss: "cancel") {
                Button("copied") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .button("akar-sparkles", help: "open dictionary") {}, message: Text("added \(Text("typeme.it").fontWeight(.medium)) to dictionary"), dismiss: "dismiss") {
                Button("undo") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .button("akar-sparkles", help: "open dictionary") {}, message: Text("learned \(counted(3, "word"))"), dismiss: "dismiss") {
                Button("undo") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(message: Text("undone")) {}
            group("updates")
            SquarePrompt(mark: .icon("akar-sparkles"), message: Text("version \(Text("1.0.1").fontWeight(.medium)) is ready"), dismiss: "later") {
                Button("install") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-sparkles"), message: Text("version 1.0.1 didn't download"), failed: true, dismiss: "dismiss") {}
            group("meetings")
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("record this meeting?"), dismiss: "not now") {
                Button("record") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("recording again · slack"), dismiss: "dismiss") {
                Button("stop") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("meeting saved"), dismiss: "dismiss") {
                Button("show") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("meeting saved"), dismiss: "dismiss") {
                Button("run hooks") {}.buttonStyle(SquareButtonStyle(kind: .quiet))
                Button("show") {}.buttonStyle(SquareButtonStyle(kind: .primary))
            }
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("2 hooks done"), dismiss: "dismiss") {
                Button("view") {}.buttonStyle(SquareButtonStyle(kind: .primary))
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
