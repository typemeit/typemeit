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
    /// False for a shortcut the app cannot do without: no cross, and ⌫ does
    /// not clear it.
    var clearable = true
    /// Told when any recorder starts or stops listening, so system hotkeys
    /// can step aside and the keys reach the recorder.
    static var listeningChanged: (@MainActor (Bool) -> Void)?
    @State private var recorder = UUID()
    /// Drawn listening with no key monitor, for a preview of that state.
    @State private var previewsListening: Bool
    @State private var hovering = false
    @Environment(\.squarePose) private var pose

    /// `listening` draws it listening, for a preview of that state.
    init(combo: Binding<KeyCombo?>, clearable: Bool = true, listening: Bool = false) {
        _combo = combo
        self.clearable = clearable
        _previewsListening = State(initialValue: listening)
    }

    private var listening: Bool { previewsListening || SquareShortcutListening.shared.recorder == recorder }

    var body: some View {
        HStack(spacing: 6) {
            Button { listening ? stop() : start() } label: { face }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(listening ? (clearable ? "esc to cancel, ⌫ to clear" : "esc to cancel") : "click, then press the keys")
            if clearable, combo != nil, !listening {
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
            // to a real edge and full ink, on a button's wash.
            let hot = pose.hot(hovering)
            prompt("set shortcut")
                .foregroundStyle(hot ? DesignTokens.Colors.ink : DesignTokens.Colors.ink2)
                .overlay(Rectangle().strokeBorder(hot ? DesignTokens.Colors.ink : DesignTokens.Colors.inkA20, lineWidth: DesignTokens.hairline))
                .background(hot ? DesignTokens.Colors.inkA08 : .clear)
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
        SquareShortcutListening.shared.start(recorder) { event in
            let bare = KeyCombo.Modifiers(event.modifierFlags).isEmpty
            if event.keyCode == 53, bare {  // esc
                stop()
            } else if event.keyCode == 51, bare, clearable {  // delete
                combo = nil
                stop()
            } else if let new = KeyCombo(event: event) {
                combo = new
                stop()
            }
        }
    }

    private func stop() {
        SquareShortcutListening.shared.stop(recorder)
        previewsListening = false
    }
}

/// The one shortcut recorder listening, app-wide. Starting one stops any
/// other, so a key lands in one recorder only, and system hotkeys stay
/// paused exactly while some recorder listens.
@MainActor
@Observable
final class SquareShortcutListening {
    static let shared = SquareShortcutListening()

    private(set) var recorder: UUID?
    @ObservationIgnored private var monitor: Any?

    private init() {}

    /// Listens for `recorder`, taking every key down from the window and
    /// handing it to `keyDown`.
    func start(_ recorder: UUID, keyDown: @escaping @MainActor (NSEvent) -> Void) {
        let wasListening = self.recorder != nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        self.recorder = recorder
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            keyDown(event)
            return nil
        }
        if !wasListening { SquareShortcutRecorder.listeningChanged?(true) }
    }

    /// Stops listening, unless another recorder has taken over since.
    func stop(_ recorder: UUID) {
        guard self.recorder == recorder else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        self.recorder = nil
        SquareShortcutRecorder.listeningChanged?(false)
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

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "try it") { SquareShortcutRecorder(combo: $copy) }
        }
    }
}

#Preview("key") { SquareKeySpecimen() }
#Preview("recorder") { SquareRecorderSpecimen() }
#endif
