import SwiftUI

/// How far a download has got, drawn as the menu bar puff in pixels: its
/// strokes on a square grid, lit clockwise from twelve o'clock as the
/// fraction grows. Unlit cells show faintly, so the whole puff is there from
/// the start and the gap left reads as what is still to come.
struct SquarePuffProgress: View {
    let fraction: Double
    var side: CGFloat = 56

    var body: some View {
        Canvas { context, size in
            let cell = min(size.width, size.height) / CGFloat(PuffPixels.size)
            // A hairline between cells keeps them reading as pixels.
            let gap = cell >= 3 ? 1 : cell * 0.2
            let lit = PuffPixels.litCount(fraction)
            for (index, c) in PuffPixels.cells.enumerated() {
                let rect = CGRect(x: CGFloat(c.column) * cell, y: CGFloat(c.row) * cell, width: cell - gap, height: cell - gap)
                context.fill(Path(rect), with: .color(index < lit ? DesignTokens.Colors.ink : DesignTokens.Colors.inkA12))
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel("download")
        .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent")
    }
}

/// The menu bar puff (Support/Icon/puff.svg) on a 28 × 28 grid. The SVG's
/// eleven arcs are kept here as circles, worked out from its arc commands:
/// a cell belongs to the puff when its centre is within 0.7 cells of one.
/// If puff.svg changes, these change with it.
enum PuffPixels {
    static let size = 28

    struct Cell: Equatable, Hashable {
        let column: Int
        let row: Int
    }

    /// Every cell of the puff, in the order a download lights them:
    /// clockwise round the grid's centre, starting at twelve o'clock.
    static let cells: [Cell] = build()

    /// How many of `cells` a fraction lights; a cell lights only once the
    /// download has passed it.
    static func litCount(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * Double(cells.count)).rounded(.down))
    }

    /// A circular arc in SVG units (y down): centre, radius, start angle and
    /// signed sweep in radians.
    private struct Arc {
        let cx, cy, r, start, sweep: Double
    }

    private static let arcs: [Arc] = [
        // The outline, seven lobes.
        Arc(cx: 36.997, cy: 43.528, r: 6.0, start: 0.0471, sweep: 2.1296),
        Arc(cx: 26.430, cy: 44.871, r: 8.0, start: 0.4652, sweep: 2.8703),
        Arc(cx: 20.174, cy: 36.001, r: 7.5, start: 1.7850, sweep: 1.8804),
        Arc(cx: 21.677, cy: 27.121, r: 9.5, start: 2.5713, sweep: 2.0297),
        Arc(cx: 32.461, cy: 23.046, r: 13.0, start: -2.7161, sweep: 2.4294),
        Arc(cx: 43.737, cy: 28.291, r: 9.0, start: -1.4379, sweep: 2.1931),
        Arc(cx: 44.544, cy: 37.498, r: 6.5, start: -0.4864, sweep: 2.2986),
        // The inner arcs, where front lobes overlap the ones behind.
        Arc(cx: 26.429, cy: 44.873, r: 8.0, start: 0.4650, sweep: -0.7103),
        Arc(cx: 21.676, cy: 27.120, r: 9.5, start: 2.5712, sweep: -0.9997),
        Arc(cx: 32.463, cy: 23.041, r: 13.0, start: -2.7165, sweep: -0.9433),
        Arc(cx: 43.731, cy: 28.290, r: 9.0, start: -1.4372, sweep: -1.5223),
    ]

    /// The square of SVG units the grid covers: the drawing's bounds plus a
    /// stroke's width, centred.
    private static let originX = 9.5447, originY = 8.5465, span = 45.8239

    private static func wrapped(_ angle: Double) -> Double {
        let t = angle.truncatingRemainder(dividingBy: 2 * .pi)
        return t < 0 ? t + 2 * .pi : t
    }

    /// Distance from a point to the nearest arc, in SVG units.
    static func distance(_ x: Double, _ y: Double) -> Double {
        var best = Double.infinity
        for arc in arcs {
            let angle = atan2(y - arc.cy, x - arc.cx)
            let inside = arc.sweep >= 0
                ? wrapped(angle - arc.start) <= arc.sweep
                : wrapped(arc.start - angle) <= -arc.sweep
            let d: Double
            if inside {
                d = abs(hypot(x - arc.cx, y - arc.cy) - arc.r)
            } else {
                let end = arc.start + arc.sweep
                d = min(hypot(x - arc.cx - arc.r * cos(arc.start), y - arc.cy - arc.r * sin(arc.start)),
                        hypot(x - arc.cx - arc.r * cos(end), y - arc.cy - arc.r * sin(end)))
            }
            best = min(best, d)
        }
        return best
    }

    private static func build() -> [Cell] {
        let unit = span / Double(size)
        let mid = Double(size) / 2
        var found: [(cell: Cell, turn: Double)] = []
        for row in 0..<size {
            for column in 0..<size {
                let x = originX + (Double(column) + 0.5) * unit
                let y = originY + (Double(row) + 0.5) * unit
                guard distance(x, y) < 0.7 * unit else { continue }
                // 0 at twelve o'clock, growing clockwise on a y-down grid.
                let turn = wrapped(atan2(Double(column) + 0.5 - mid, mid - Double(row) - 0.5))
                found.append((Cell(column: column, row: row), turn))
            }
        }
        return found.sorted { $0.turn < $1.turn }.map(\.cell)
    }
}
