import Foundation

/// The meetings part of the insights page, from the transcribed meetings.
/// Pure: the meetings and the clock are passed in.
struct MeetingStats: Equatable, Sendable {
    var meetings: Int
    var meetingsThisMonth: Int
    var totalMs: Int
    var thisMonthMs: Int
    /// On calls only: a room has no side that is known to be yours.
    var yourTalkMs: Int
    var callTalkMs: Int
    var medianMs: Int?
    var longestMs: Int?
    /// The app with the most calls, nil with no calls.
    var topApp: String?
}

enum MeetingInsights {
    static func compute(_ all: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> MeetingStats {
        let meetings = all.filter(\.isDone)
        let thisMonth = meetings.filter { calendar.isDate($0.started, equalTo: now, toGranularity: .month) }
        let calls = meetings.filter { $0.kind == .call }
        let lengths = meetings.map(\.durationMs).sorted()
        var byApp: [String: Int] = [:]
        for call in calls { if let app = call.app?.name { byApp[app, default: 0] += 1 } }
        return MeetingStats(
            meetings: meetings.count,
            meetingsThisMonth: thisMonth.count,
            totalMs: lengths.reduce(0, +),
            thisMonthMs: thisMonth.map(\.durationMs).reduce(0, +),
            yourTalkMs: calls.flatMap(\.speakers).filter(\.isYou).map(\.talkMs).reduce(0, +),
            callTalkMs: calls.flatMap(\.speakers).map(\.talkMs).reduce(0, +),
            medianMs: lengths.isEmpty ? nil : lengths[(lengths.count - 1) / 2],
            longestMs: lengths.last,
            topApp: byApp.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key)
    }
}
