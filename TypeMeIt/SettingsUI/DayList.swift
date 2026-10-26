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
}

extension Binding where Value == ListSelection {
    /// A row's select box. `rows` is what the list shows at the click.
    func box(_ id: UUID, rows: @escaping () -> [UUID]) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.picked.contains(id) },
            // A SwiftUI toggle hands its action no event, so the modifier is
            // read from the keyboard as the click lands.
            set: { _ in wrappedValue.click(id, extending: NSEvent.modifierFlags.contains(.shift), in: rows()) })
    }
}
