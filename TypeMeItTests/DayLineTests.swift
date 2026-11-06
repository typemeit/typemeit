import Foundation
import Testing
@testable import TypeMeIt

/// The day lines the dictations and the meetings lists are drawn from.
@MainActor
struct DayLineTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Noon on a day in October 2025, far enough back that no day is today.
    private static func noon(_ day: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2025, month: 10, day: day, hour: 12, minute: minute))!
    }

    private struct Row: Identifiable {
        let id = UUID()
        let at: Date
    }

    /// A day line as "day <start of day> <total>", a row as its id.
    private static func described<Row>(_ lines: [DayLine<Row>]) -> [String] {
        lines.map { line in
            switch line {
            case .day(let id, let day, let date, let total):
                let label = HistoryTab.dayLabel(id, calendar: calendar)
                #expect(day == label.day)
                #expect(date == label.date)
                return "day \(id.timeIntervalSince1970) \(total)"
            case .row(let row): return row.id.uuidString
            }
        }
    }

    @Test func rowsFallUnderALineForTheirDay() {
        let rows = [Row(at: Self.noon(9, minute: 30)), Row(at: Self.noon(9)), Row(at: Self.noon(7))]
        let lines = DayLine.lines(rows, on: \.at, total: { "\($0.count)" }, calendar: Self.calendar)
        #expect(Self.described(lines) == [
            "day \(Self.calendar.startOfDay(for: Self.noon(9)).timeIntervalSince1970) 2",
            rows[0].id.uuidString,
            rows[1].id.uuidString,
            "day \(Self.calendar.startOfDay(for: Self.noon(7)).timeIntervalSince1970) 1",
            rows[2].id.uuidString,
        ])
    }

    @Test func aShortStampNamesTheDayOnlyBeforeToday() {
        let now = Date.now
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        #expect(HistoryTab.shortStamp(now) == HistoryTab.clock(now))
        #expect(HistoryTab.shortStamp(yesterday) == "yesterday \(HistoryTab.clock(yesterday))")
    }

    @Test func noRowsIsNoLines() {
        #expect(DayLine<Row>.lines([], on: \.at, total: { _ in "" }, calendar: Self.calendar).isEmpty)
    }

    @Test func dictationsTotalTheirCountAndWords() {
        let rows = [
            HistoryEntry(timestamp: Self.noon(9, minute: 5), transcript: "one two three", postProcessed: nil, postProcessRequested: false, typed: nil, dictionaryFixes: 0),
            HistoryEntry(timestamp: Self.noon(9), transcript: "four", postProcessed: nil, postProcessRequested: false, typed: nil, dictionaryFixes: 0),
            HistoryEntry(timestamp: Self.noon(8), transcript: "five six", postProcessed: nil, postProcessRequested: false, typed: nil, dictionaryFixes: 0),
        ]
        #expect(Self.described(HistoryTab.lines(rows, calendar: Self.calendar)) == [
            "day \(Self.calendar.startOfDay(for: Self.noon(9)).timeIntervalSince1970) 2 dictations · 4 words",
            rows[0].id.uuidString,
            rows[1].id.uuidString,
            "day \(Self.calendar.startOfDay(for: Self.noon(8)).timeIntervalSince1970) 1 dictation · 2 words",
            rows[2].id.uuidString,
        ])
    }

    @Test func meetingsTotalTheirCountAndLength() {
        var first = MeetingFixtures.example
        first.id = UUID()
        first.started = Self.noon(9, minute: 40)
        first.durationMs = 2_076_000
        var second = MeetingFixtures.example
        second.id = UUID()
        second.started = Self.noon(9)
        second.durationMs = 2_076_000
        var third = MeetingFixtures.example
        third.id = UUID()
        third.started = Self.noon(6)
        third.durationMs = 660_000
        #expect(Self.described(MeetingsTab.lines([first, second, third], calendar: Self.calendar)) == [
            "day \(Self.calendar.startOfDay(for: Self.noon(9)).timeIntervalSince1970) 2 meetings · 1h 09m",
            first.id.uuidString,
            second.id.uuidString,
            "day \(Self.calendar.startOfDay(for: Self.noon(6)).timeIntervalSince1970) 1 meeting · 11m",
            third.id.uuidString,
        ])
    }
}
