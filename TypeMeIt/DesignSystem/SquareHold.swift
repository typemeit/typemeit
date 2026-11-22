import SwiftUI

/// Hold to confirm, in place of a question: pressing and holding fills the
/// control with the slab from the left, its edge a band of dither, and once
/// it is full the action runs. Letting go early drains the fill back out in
/// the square parts' steps. For deleting one thing; deleting many still asks.
enum SquareHold {
    /// How long the press takes.
    static let length: Duration = .milliseconds(1200)
    /// How much of the fill a frame of holding adds, and letting go takes away.
    static var gain: Double { SquarePixel.frameTime / length }
    static let drain: Double = 2.0 / 16
    /// How wide the dithered edge in front of the fill is.
    static let edge: CGFloat = 10
}

private struct SquareHoldPress: ViewModifier {
    @Binding var progress: Double
    let name: String
    let action: () -> Void
    @State private var holding = false
    @State private var run: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding else { return }
                    holding = true
                    drive()
                }
                .onEnded { _ in
                    holding = false
                    drive()
                })
            // A screen reader can't hold, so the action is offered by name.
            .accessibilityAction(named: name, action)
            .onDisappear {
                run?.cancel()
                run = nil
            }
    }

    /// Fills while held and drains once let go, a frame at a time, until
    /// the fill is full (and the action runs) or empty.
    private func drive() {
        guard run == nil else { return }
        run = Task {
            _ = await SquarePixel.run {
                if holding {
                    progress = min(1, progress + SquareHold.gain)
                    if progress >= 1 {
                        holding = false
                        progress = 0
                        action()
                        return false
                    }
                    return true
                }
                progress = max(0, progress - SquareHold.drain)
                return progress > 0
            }
            run = nil
        }
    }
}

/// The fill of a hold, `progress` of the way across: solid behind, then
/// the dithered edge thinning to nothing ahead of it.
struct SquareSweep: View {
    let progress: Double
    var color: Color = DesignTokens.Colors.slab

    var body: some View {
        Canvas { context, size in
            let edge = SquareHold.edge, cell: CGFloat = 2
            let front = CGFloat(progress) * (size.width + edge)
            let solid = max(0, front - edge)
            var path = Path(CGRect(x: 0, y: 0, width: min(solid, size.width), height: size.height))
            let rows = Int((size.height / cell).rounded(.up))
            var column = Int(solid / cell)
            while CGFloat(column) * cell < min(front, size.width) {
                let x = CGFloat(column) * cell
                // 16 of 16 cells just behind the solid part, fewer towards the front.
                let level = Int((16 * (front - x) / edge / 4).rounded(.up)) * 4
                for row in 0..<rows where SquarePixel.inked(column: column, row: row, level: level) {
                    path.addRect(CGRect(x: x, y: CGFloat(row) * cell, width: cell, height: cell))
                }
                column += 1
            }
            context.fill(path, with: .color(color))
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Runs `action` once this has been held for `SquareHold.length`,
    /// reporting how far the hold has got in `progress`. Put it on a button
    /// whose own action does nothing, so a click alone deletes nothing;
    /// `name` is the action a screen reader offers instead.
    func squareHold(progress: Binding<Double>, name: String, perform action: @escaping () -> Void) -> some View {
        modifier(SquareHoldPress(progress: progress, name: name, action: action))
    }

    /// Fills this with a hold's sweep, inverting what is under it: ink on
    /// paper turns to on-slab on the slab, in either appearance, since the
    /// two are each other's opposites.
    func squareHoldFill(_ progress: Double) -> some View {
        background(progress > 0 ? DesignTokens.Colors.paper : Color.clear)
            .overlay {
                if progress > 0 {
                    SquareSweep(progress: progress, color: .white).blendMode(.difference)
                }
            }
            .compositingGroup()
    }
}

#if DEBUG
/// Each kind of hold in the app: a row's bin, a hook's delete, a word's cross.
struct SquareHoldSpecimen: View {
    @State private var bin = 0.0
    @State private var button = 0.0
    @State private var gone: Set<String> = []

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "icon") {
                if gone.contains("icon") { done("icon") } else {
                    Button {} label: { SquareIcon("akar-trash-can", size: 14) }
                        .buttonStyle(SquareIconButtonStyle())
                        .squareHold(progress: $bin, name: "delete") { gone.insert("icon") }
                        .squareHoldFill(bin)
                        .help("hold to delete")
                }
            }
            SquareSpecimenLine(name: "button") {
                if gone.contains("button") { done("button") } else {
                    Button("delete") {}
                        .buttonStyle(SquareButtonStyle(kind: .quiet, small: true))
                        .squareHold(progress: $button, name: "delete") { gone.insert("button") }
                        .squareHoldFill(button)
                        .help("hold to delete")
                }
            }
            SquareSpecimenLine(name: "chip") {
                if gone.contains("chip") { done("chip") } else {
                    SquareWordChip(word: "kubernetes", heardAs: ["cooper netties"], forget: { gone.insert("chip") })
                }
            }
        }
    }

    private func done(_ key: String) -> some View {
        Button("put it back") { gone.remove(key) }.buttonStyle(SquareButtonStyle(kind: .quiet, small: true))
    }
}

#Preview("hold") { SquareHoldSpecimen().padding(24) }
#endif
