import SwiftUI

/// The square parts' one motion: things move in a few hard steps, a frame
/// apart, and what they leave behind thins out as a 2 pt dither. The tabs'
/// slab set the numbers; the choice, switch, tick, screen picker, filter and
/// hold all use them. Under Reduce Motion a move lands at once.
enum SquarePixel {
    /// How many steps a jump takes.
    static let steps = 4
    /// How far apart the steps are.
    static let frameTime: Duration = .milliseconds(35)
    /// How many of every 16 cells a ghost starts with, and how many it loses a frame.
    static let ghostStart = 10
    static let ghostThin = 2

    /// Runs `frame` once a frame until it returns false. False if the task
    /// was cancelled before then, so the caller leaves things to whoever
    /// cancelled it.
    @MainActor static func run(_ frame: () -> Bool) async -> Bool {
        repeat {
            try? await Task.sleep(for: frameTime)
            if Task.isCancelled { return false }
        } while frame()
        return true
    }

    /// The level `step` of `steps` of the way from one level to another, 0...16.
    static func level(from: Int, to: Int, step: Int) -> Int {
        from + (to - from) * step / steps
    }

    /// The frame `step` of `steps` of the way from one rect to another, on whole points.
    static func rect(from: CGRect, to: CGRect, step: Int) -> CGRect {
        let k = CGFloat(step) / CGFloat(steps)
        return CGRect(x: (from.minX + (to.minX - from.minX) * k).rounded(),
                      y: (from.minY + (to.minY - from.minY) * k).rounded(),
                      width: (from.width + (to.width - from.width) * k).rounded(),
                      height: (from.height + (to.height - from.height) * k).rounded())
    }

    static func point(from: CGPoint, to: CGPoint, step: Int) -> CGPoint {
        let k = CGFloat(step) / CGFloat(steps)
        return CGPoint(x: (from.x + (to.x - from.x) * k).rounded(), y: (from.y + (to.y - from.y) * k).rounded())
    }

    /// The order a 4 × 4 block's cells fill in.
    static let bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

    /// Whether the cell at `column`, `row` is inked at `level` of 16.
    static func inked(column: Int, row: Int, level: Int) -> Bool {
        bayer[(row % 4) * 4 + column % 4] < level
    }
}

/// A 2 pt ordered dither: `level` of every 16 cells in a 4 × 4 Bayer block
/// are filled, so 8 is a checker and 16 is solid.
struct SquareDither: View {
    let level: Int
    var color: Color = DesignTokens.Colors.ink
    var cell: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            guard level > 0 else { return }
            if level >= 16 {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color))
                return
            }
            let columns = Int((size.width / cell).rounded(.up)), rows = Int((size.height / cell).rounded(.up))
            var path = Path()
            for row in 0..<rows {
                for column in 0..<columns where SquarePixel.inked(column: column, row: row, level: level) {
                    path.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(color))
        }
        .allowsHitTesting(false)
    }
}

/// A slab that jumps to a new place in `SquarePixel.steps` hard steps and
/// leaves a dithered ghost where it was, thinning out a little each frame.
/// The tabs and the choice draw one under their labels.
struct SquareSlabMotion {
    /// Where the slab is drawn; nil until its parts are laid out.
    var slab: CGRect?
    /// Where it was, while the ghost fades.
    private(set) var ghost: CGRect?
    /// How many of every 16 of the ghost's cells are inked.
    private(set) var ghostLevel = 0
    private var from: CGRect?
    private var target: CGRect?
    private var step = 0

    /// Starts a jump to `target`. False when there is nothing to animate (no
    /// slab yet, the same place, Reduce Motion) and the slab is simply there.
    mutating func start(to target: CGRect, reduceMotion: Bool) -> Bool {
        guard let slab, slab != target, !reduceMotion else {
            settle(at: target)
            return false
        }
        from = slab
        self.target = target
        ghost = slab
        ghostLevel = SquarePixel.ghostStart
        step = 0
        return true
    }

    /// One frame of the jump. False once the slab has landed and the ghost is gone.
    mutating func advance() -> Bool {
        guard let from, let target else { return false }
        if step < SquarePixel.steps {
            step += 1
            slab = SquarePixel.rect(from: from, to: target, step: step)
        }
        ghostLevel = max(0, ghostLevel - SquarePixel.ghostThin)
        return step < SquarePixel.steps || ghostLevel > 0
    }

    /// Puts the slab on `frame` with no ghost: where a jump ends, since the
    /// layout may have moved while it ran.
    mutating func settle(at frame: CGRect?) {
        if let frame { slab = frame }
        ghost = nil
        ghostLevel = 0
        from = nil
        target = nil
    }

    /// Whether the slab covers the middle of `frame` along `axis`, so a label
    /// there is drawn on the slab. Nil before layout.
    func covers(_ frame: CGRect?, axis: Axis = .horizontal) -> Bool? {
        guard let slab, let frame else { return nil }
        return axis == .horizontal
            ? slab.minX <= frame.midX && frame.midX <= slab.maxX
            : slab.minY <= frame.midY && frame.midY <= slab.maxY
    }
}

/// The ghost and the slab of a `SquareSlabMotion`, for a background in the
/// space its frames were measured in.
struct SquareSlabLayer: View {
    let motion: SquareSlabMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let ghost = motion.ghost, motion.ghostLevel > 0 {
                SquareDither(level: motion.ghostLevel, color: DesignTokens.Colors.slab)
                    .frame(width: ghost.width, height: ghost.height)
                    .offset(x: ghost.minX, y: ghost.minY)
            }
            if let slab = motion.slab {
                Rectangle()
                    .fill(DesignTokens.Colors.slab)
                    .frame(width: slab.width, height: slab.height)
                    .offset(x: slab.minX, y: slab.minY)
            }
        }
        .allowsHitTesting(false)
    }
}
