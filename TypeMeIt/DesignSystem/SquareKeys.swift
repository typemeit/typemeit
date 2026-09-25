import AppKit
import SwiftUI

/// A key: its label in mono on paper, on an ink-a32 edge twice as thick at
/// the bottom, like a keycap seen from the front.
struct SquareKeycap: View {
    let text: String

    init(_ text: String) { self.text = text }

    static let side: CGFloat = 22

    var body: some View {
        Text(text)
            .font(Square.mono(Square.controlSize))
            .foregroundStyle(DesignTokens.Colors.ink)
            .centredLetters(text)
            // Centred between the top edge and the thicker bottom one.
            .padding(.bottom, DesignTokens.hairline)
            .padding(.horizontal, 6)
            .frame(minWidth: SquareKeycap.side)
            .frame(height: SquareKeycap.side)
            .background(DesignTokens.Colors.paper)
            .overlay(Rectangle().strokeBorder(DesignTokens.Colors.inkA32, lineWidth: DesignTokens.hairline))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DesignTokens.Colors.inkA32)
                    .frame(height: DesignTokens.hairline)
                    .padding(.horizontal, DesignTokens.hairline)
                    .padding(.bottom, DesignTokens.hairline)
            }
    }
}

/// A shortcut as keycaps, or "set shortcut" when there is none. A click
/// listens; the next key with ⌘, ⌥ or ⌃ becomes the shortcut, esc gives up,
/// and ⌫ on its own clears it. The cross beside a set shortcut clears it too.
struct SquareShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var listening: Bool
    @State private var monitor: Any?
    @State private var hovering = false
    @Environment(\.squarePose) private var pose

    /// `listening` starts it listening, for a preview of that state.
    init(combo: Binding<KeyCombo?>, listening: Bool = false) {
        _combo = combo
        _listening = State(initialValue: listening)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { listening ? stop() : start() } label: { face }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(listening ? "esc to cancel, ⌫ to clear" : "click, then press the keys")
            if combo != nil, !listening {
                Button { combo = nil } label: { SquareIcon("akar-cross", size: 8) }
                    .buttonStyle(SquareIconButtonStyle(side: SquareKeycap.side))
                    .help("clear")
                    .accessibilityLabel("clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    @ViewBuilder private var face: some View {
        if listening {
            prompt("press keys…")
                .foregroundStyle(DesignTokens.Colors.ink)
                // Dashed until a key lands.
                .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, style: SquareEdge.style(dashed: true)))
        } else if let combo {
            HStack(spacing: 4) { ForEach(combo.caps, id: \.self) { SquareKeycap($0) } }
        } else {
            // An empty outline reads as furniture, so the pointer brings it up
            // to a real edge and full ink, casting a button's shadow.
            let hot = pose.hot(hovering)
            prompt("set shortcut")
                .foregroundStyle(hot ? DesignTokens.Colors.ink : DesignTokens.Colors.ink2)
                .overlay(Rectangle().strokeBorder(hot ? DesignTokens.Colors.ink : DesignTokens.Colors.inkA20, lineWidth: DesignTokens.hairline))
                .squarePress(hot: hot, down: false, shadow: DesignTokens.Colors.ink)
        }
    }

    private func prompt(_ text: String) -> some View {
        Text(text)
            .font(Square.mono(Square.controlSize))
            .centredLetters(text)
            .padding(.horizontal, 10)
            .frame(height: SquareButtonStyle.height)
            .contentShape(Rectangle())
    }

    private func start() {
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let bare = KeyCombo.Modifiers(event.modifierFlags).isEmpty
            if event.keyCode == 53, bare {  // esc
                stop()
            } else if event.keyCode == 51, bare {  // delete
                combo = nil
                stop()
            } else if let new = KeyCombo(event: event) {
                combo = new
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
    }
}

#if DEBUG
struct SquareKeySpecimen: View {
    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "combo") { HStack(spacing: 4) { ForEach(["⇧", "⌘", "C"], id: \.self) { SquareKeycap($0) } } }
            SquareSpecimenLine(name: "words") { HStack(spacing: 10) { ForEach(["fn", "space", "esc"], id: \.self) { SquareKeycap($0) } } }
        }
    }
}

struct SquareRecorderSpecimen: View {
    @State private var copy: KeyCombo? = KeyCombo(keyCode: 8, modifiers: [.shift, .command], keyLabel: "C")
    @State private var room: KeyCombo?

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "set") { SquareShortcutRecorder(combo: $copy) }
            SquareSpecimenLine(name: "unset") { SquareShortcutRecorder(combo: $room) }
            SquareSpecimenLine(name: "hover", pose: .hover) { SquareShortcutRecorder(combo: .constant(nil)) }
            SquareSpecimenLine(name: "listening") { SquareShortcutRecorder(combo: .constant(nil), listening: true) }
        }
    }
}

#Preview("key") { SquareKeySpecimen() }
#Preview("recorder") { SquareRecorderSpecimen() }
#endif
