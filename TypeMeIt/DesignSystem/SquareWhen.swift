import SwiftUI

/// What a list is filtered to in time: a preset, or a run of days picked on
/// the calendar.
enum SquareWhen: Hashable, Sendable {
    case any, today, yesterday, thisWeek, last7Days, thisMonth
    case days(ClosedRange<Date>)

    static let presets: [SquareWhen] = [.any, .today, .yesterday, .thisWeek, .last7Days, .thisMonth]

    var label: String {
        switch self {
        case .any: "any time"
        case .today: "today"
        case .yesterday: "yesterday"
        case .thisWeek: "this week"
        case .last7Days: "last 7 days"
        case .thisMonth: "this month"
        case .days(let r):
            Calendar.current.isDate(r.lowerBound, inSameDayAs: r.upperBound)
                ? r.lowerBound.formatted(.dateTime.day().month(.abbreviated)).lowercased()
                : "\(r.lowerBound.formatted(.dateTime.day())) – \(r.upperBound.formatted(.dateTime.day().month(.abbreviated)).lowercased())"
        }
    }

    /// The days it covers, as the calendar draws them; nil for any time.
    func span(today: Date, calendar: Calendar = .current) -> ClosedRange<Date>? {
        let day = calendar.startOfDay(for: today)
        func back(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: day) ?? day }
        switch self {
        case .any: return nil
        case .today: return day...day
        case .yesterday: return back(1)...back(1)
        case .thisWeek: return (calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day)...day
        case .last7Days: return back(6)...day
        case .thisMonth: return (calendar.dateInterval(of: .month, for: day)?.start ?? day)...day
        case .days(let r): return r
        }
    }
}

/// The when filter's popover: the presets down the left, and on the right a
/// month to pick a run of days on, then a time of day.
struct SquareWhenPicker: View {
    @Binding var when: SquareWhen
    @Binding var from: String
    @Binding var to: String
    var today: Date = .now

    var body: some View {
        SquarePanel {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(SquareWhen.presets, id: \.self) { preset in
                        SquareWhenPreset(label: preset.label, checked: preset == when) { when = preset }
                    }
                }
                .padding(.vertical, 6)
                .frame(width: 136)
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .trailing) { Rectangle().fill(DesignTokens.Colors.rule).frame(width: DesignTokens.hairline) }
                VStack(spacing: 0) {
                    SquareCalendar(when: $when, today: today)
                    HStack(spacing: 6) {
                        Text("time of day").font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SquareTimeField(placeholder: "00:00", text: $from)
                        Text("–").font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3)
                        SquareTimeField(placeholder: "23:59", text: $to)
                    }
                    .padding(.top, 10)
                    .overlay(alignment: .top) { SquareRule() }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
        }
        .fixedSize()
    }
}

private struct SquareWhenPreset: View {
    let label: String
    let checked: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(checked ? DesignTokens.Colors.ink : .clear)
                    .overlay(Rectangle().strokeBorder(checked ? DesignTokens.Colors.ink : DesignTokens.Colors.ruleControl, lineWidth: DesignTokens.hairline))
                    .frame(width: 10, height: 10)
                Text(label).font(Square.mono(Square.controlSize)).centredLetters(label)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DesignTokens.Colors.ink)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Rectangle().fill(hovering ? DesignTokens.Colors.inkA08 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

private struct SquareTimeField: View {
    let placeholder: String
    @Binding var text: String
    @State private var focused = false

    var body: some View {
        SquareTextInput(placeholder: placeholder, text: $text, font: Square.appKitMono(11), focused: $focused)
            .padding(.horizontal, 6)
            .frame(width: 58, height: 24)
            .overlay(Rectangle().strokeBorder(focused ? DesignTokens.Colors.ink : DesignTokens.Colors.ruleControl, lineWidth: DesignTokens.hairline))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
    }
}

/// A month of days to pick a run on. The run is washed, its two ends are on
/// the slab, today is underlined, and days to come are out of reach. The
/// first click starts a run on that day; the second ends it.
struct SquareCalendar: View {
    @Binding var when: SquareWhen
    var today: Date = .now
    @State private var month: Date?
    @State private var picking: Date?

    private let calendar = Calendar.current

    var body: some View {
        let shown = month ?? calendar.dateInterval(of: .month, for: when.span(today: today)?.upperBound ?? today)?.start ?? today
        VStack(spacing: 0) {
            HStack {
                step("previous month", by: -1, from: shown, turn: 90)
                Spacer()
                Text(shown.formatted(.dateTime.month(.wide).year()).lowercased()).font(Square.mono(Square.controlSize))
                Spacer()
                step("next month", by: 1, from: shown, turn: -90)
            }
            .frame(height: 28)
            .padding(.bottom, 2)
            Grid(horizontalSpacing: 0, verticalSpacing: 2) {
                GridRow {
                    ForEach(weekdays.indices, id: \.self) { i in
                        Text(weekdays[i]).font(Square.mono(10)).foregroundStyle(DesignTokens.Colors.ink3)
                            .frame(width: CalendarMetrics.column, height: 22)
                    }
                }
                ForEach(weeks(of: shown), id: \.self) { week in
                    GridRow {
                        ForEach(week, id: \.self) { day in cell(day, in: shown) }
                    }
                }
            }
        }
        .foregroundStyle(DesignTokens.Colors.ink)
        .frame(width: CalendarMetrics.column * CGFloat(weekdays.count))
    }

    /// The weekday letters from the calendar's first weekday on.
    private var weekdays: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols.map { $0.lowercased() }
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Whole weeks covering the month, starting on the calendar's first weekday.
    private func weeks(of month: Date) -> [[Date]] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: interval.start) else { return [] }
        var weeks: [[Date]] = []
        var day = firstWeek.start
        while day < interval.end {
            let week = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: day) }
            weeks.append(week)
            day = calendar.date(byAdding: .day, value: 7, to: day) ?? interval.end
        }
        return weeks
    }

    private func cell(_ day: Date, in month: Date) -> some View {
        let span = when.span(today: today, calendar: calendar)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let future = day > calendar.startOfDay(for: today)
        let reachable = inMonth && !future
        let end = span.map { calendar.isDate(day, inSameDayAs: $0.lowerBound) || calendar.isDate(day, inSameDayAs: $0.upperBound) } ?? false
        let inside = span?.contains(day) ?? false
        let isToday = calendar.isDate(day, inSameDayAs: today)
        return SquareCalendarDay(
            number: calendar.component(.day, from: day),
            look: !reachable ? .out : end ? .end : inside ? .inside : .plain,
            today: isToday
        ) { pick(day) }
        .disabled(!reachable)
    }

    private func pick(_ day: Date) {
        if let start = picking {
            when = .days(min(start, day)...max(start, day))
            picking = nil
        } else {
            when = .days(day...day)
            picking = day
        }
    }

    private func step(_ help: String, by months: Int, from shown: Date, turn: Double) -> some View {
        Button { month = calendar.date(byAdding: .month, value: months, to: shown) } label: {
            SquareIcon("akar-chevron-down", size: 10).rotationEffect(.degrees(turn))
        }
        .buttonStyle(SquareIconButtonStyle(side: 22))
        .help(help)
        .accessibilityLabel(help)
    }
}

private enum CalendarMetrics {
    static let column: CGFloat = 32
    static let row: CGFloat = 30
}

private struct SquareCalendarDay: View {
    enum Look { case plain, inside, end, out }
    let number: Int
    let look: Look
    let today: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            Text("\(number)")
                .font(Square.mono(Square.controlSize))
                .monospacedDigit()
                .underline(today)
                .foregroundStyle(foreground)
                .frame(width: CalendarMetrics.column, height: CalendarMetrics.row)
                .background(Rectangle().fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch look {
        case .end: DesignTokens.Colors.onSlab
        case .out: DesignTokens.Colors.ink3
        case .plain, .inside: DesignTokens.Colors.ink
        }
    }

    private var fill: Color {
        switch look {
        case .end: DesignTokens.Colors.slab
        case .inside: DesignTokens.Colors.inkA08
        case .out: .clear
        case .plain: hovering ? DesignTokens.Colors.inkA08 : .clear
        }
    }
}

#if DEBUG
struct SquareWhenSpecimen: View {
    @State private var when = SquareWhen.thisWeek
    @State private var from = ""
    @State private var to = ""
    @State private var open = false

    /// Thursday 24 september 2026, the day the canvas is set on.
    private static let today = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 24)) ?? .now

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "filter") {
                SquareFilter(label: when == .any ? "when" : when.label, active: when != .any, clear: { when = .any }, open: $open) {
                    SquareWhenPicker(when: $when, from: $from, to: $to, today: SquareWhenSpecimen.today)
                }
            }
            SquareSpecimenLine(name: "open") {
                SquareWhenPicker(when: $when, from: $from, to: $to, today: SquareWhenSpecimen.today)
            }
        }
    }
}

#Preview("when") { SquareWhenSpecimen() }
#endif
