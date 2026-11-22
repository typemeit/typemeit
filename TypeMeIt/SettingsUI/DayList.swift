import AppKit
import SwiftUI

/// A list grouped by day, as the dictations and the meetings are: a line for
/// each day, then that day's rows.
enum DayLine<Row: Identifiable>: Identifiable where Row.ID == UUID {
    case day(id: Date, day: String, date: String, total: String)
    case row(Row)

    var id: String {
        switch self {
        case .day(let id, _, _, _): "day-\(id.timeIntervalSinceReferenceDate)"
        case .row(let row): row.id.uuidString
        }
    }

    /// The rows under a line for each day, in the order given, newest first;
    /// `total` says how much a day held.
    static func lines(_ rows: [Row], on date: (Row) -> Date, total: (ArraySlice<Row>) -> String,
                      calendar: Calendar = .current) -> [DayLine] {
        var out: [DayLine] = []
        var i = rows.startIndex
        while i < rows.endIndex {
            let day = calendar.startOfDay(for: date(rows[i]))
            var j = i
            while j < rows.endIndex, calendar.isDate(date(rows[j]), inSameDayAs: day) { j += 1 }
            let same = rows[i..<j]
            let label = HistoryTab.dayLabel(day, calendar: calendar)
            out.append(.day(id: day, day: label.day, date: label.date, total: total(same)))
            out.append(contentsOf: same.map(DayLine.row))
            i = j
        }
        return out
    }
}

/// The rows picked in a list, and what a click on a row's box does to them.
/// A plain click turns that one row on or off; shift-click takes every row
/// between the last box clicked and this one, so a run of rows can be
/// deleted without clicking each of them. The range is measured over the
/// rows as they are listed, which means it crosses the day headings they are
/// grouped under and never reaches a row the filters have hidden. Shift only
/// ever adds, so several runs can be gathered up before deleting. An anchor
/// that is no longer listed — the search moved on, or the row was deleted —
/// leaves shift with nothing to measure from, and the click is the plain one.
struct ListSelection {
    var picked: Set<UUID> = []
    /// The row a range is measured from: the last one whose box was clicked.
    var anchor: UUID?

    mutating func click(_ id: UUID, extending: Bool, in rows: [UUID]) {
        if extending, let anchor, let from = rows.firstIndex(of: anchor), let to = rows.firstIndex(of: id) {
            picked.formUnion(rows[min(from, to)...max(from, to)])
        } else if picked.contains(id) {
            picked.remove(id)
        } else {
            picked.insert(id)
        }
        anchor = id
    }

    /// What a drag down the boxes sets each box it crosses to: what the box
    /// it started on became. Nil while no drag is going on.
    var dragging: Bool?
    /// The last box the drag was over, which the next stretch is measured from.
    var dragAt: UUID?

    /// A press on a row's box: the click it would have been, and the start
    /// of a drag that carries what that box became down (or up) the list.
    mutating func startDrag(_ id: UUID, extending: Bool, in rows: [UUID]) {
        click(id, extending: extending, in: rows)
        dragging = picked.contains(id)
        dragAt = id
    }

    /// The drag has reached the box of `id`: every row from the last box it
    /// was over to this one takes the drag's value, so a fast drag that
    /// skips boxes leaves none out.
    mutating func drag(over id: UUID, in rows: [UUID]) {
        guard let dragging, let dragAt, dragAt != id,
              let from = rows.firstIndex(of: dragAt), let to = rows.firstIndex(of: id) else { return }
        let stretch = rows[min(from, to)...max(from, to)]
        if dragging { picked.formUnion(stretch) } else { picked.subtract(stretch) }
        self.dragAt = id
        anchor = id
    }

    mutating func endDrag() {
        dragging = nil
        dragAt = nil
    }
}

/// A list's coordinate space, where its rows' boxes are measured for a drag.
let squareListSpace = "square-list"

/// Where each row's box was last laid out in its list, for finding the box
/// a drag is over. A class, so measuring a row doesn't redraw the list; the
/// space is the list's content, so the frames hold as it scrolls.
@MainActor final class ListBoxFrames {
    private var frames: [UUID: CGRect] = [:]

    func set(_ id: UUID, _ frame: CGRect) { frames[id] = frame }

    /// The box nearest `y`, if it is within a row's reach of it, among the rows listed.
    func box(at y: CGFloat, among rows: [UUID]) -> UUID? {
        let near = rows.compactMap { id in frames[id].map { (id, abs($0.midY - y)) } }.min { $0.1 < $1.1 }
        guard let near, near.1 < 24 else { return nil }
        return near.0
    }
}

/// A row's box, with what it needs to start or carry a drag.
struct ListBoxDrag {
    let id: UUID
    let selection: Binding<ListSelection>
    let frames: ListBoxFrames
    let rows: () -> [UUID]
}

extension View {
    /// A list row's select box, ticked or unticked by a press that can go
    /// on down or up the boxes, ticking (or unticking) each one it crosses.
    /// Shift on the press extends from the last box clicked, as a click does.
    func listBoxDrag(_ drag: ListBoxDrag) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(squareListSpace)) } action: { drag.frames.set(drag.id, $0) }
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(squareListSpace))
                .onChanged { value in
                    let rows = drag.rows()
                    if drag.selection.wrappedValue.dragging == nil {
                        drag.selection.wrappedValue.startDrag(drag.id, extending: NSEvent.modifierFlags.contains(.shift), in: rows)
                    } else if let over = drag.frames.box(at: value.location.y, among: rows) {
                        drag.selection.wrappedValue.drag(over: over, in: rows)
                    }
                }
                .onEnded { _ in drag.selection.wrappedValue.endDrag() })
    }
}

extension Binding where Value == ListSelection {
    /// A row's box for `listBoxDrag`. `rows` is what the list shows.
    func drag(_ id: UUID, frames: ListBoxFrames, rows: @escaping () -> [UUID]) -> ListBoxDrag {
        ListBoxDrag(id: id, selection: self, frames: frames, rows: rows)
    }

    /// A row's select box. `rows` is what the list shows at the click.
    func box(_ id: UUID, rows: @escaping () -> [UUID]) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.picked.contains(id) },
            // A SwiftUI toggle hands its action no event, so the modifier is
            // read from the keyboard as the click lands.
            set: { _ in wrappedValue.click(id, extending: NSEvent.modifierFlags.contains(.shift), in: rows()) })
    }
}
