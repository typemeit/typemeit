import Foundation

/// Gregorian calendar in UTC, so every date in a test is a fixed instant
/// regardless of the machine's zone.
let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

/// An ISO 8601 timestamp such as "2026-01-10T09:00:00Z".
func iso(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
