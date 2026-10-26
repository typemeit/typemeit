// Aggregates the transcription history into the numbers shown on the
// Insights page: words dictated, speaking rate, fixes, per-category usage
// and the daily streak.
//
// `Insights.compute` is pure over the rows it is handed, so the whole page can
// be checked with in-memory data. Month and day boundaries follow the
// `calendar` argument; the app passes `Calendar.current`.

import Foundation

/// The columns of one history entry the insights need.
struct InsightRow: Sendable {
    var timestamp: Date
    /// What was said, which the speaking rate and time saved count.
    var transcript: String
    /// The words history shows for it (`HistoryEntry.wordCount`), which the
    /// totals count; nil counts the transcript.
    var shownWords: Int? = nil
    var postProcessed: String? = nil
    var postProcessRequested: Bool = false
    var durationMs: Int? = nil
    var transcribeMs: Int? = nil
    var postProcessMs: Int? = nil
    var dictionaryFixes: Int = 0
    var appId: String? = nil
    var appName: String? = nil
    var windowTitle: String? = nil
}

extension InsightRow {
    init(_ entry: HistoryEntry) {
        self.init(timestamp: entry.timestamp, transcript: entry.transcript, shownWords: entry.wordCount, postProcessed: entry.postProcessed,
                  postProcessRequested: entry.postProcessRequested, durationMs: entry.durationMs,
                  transcribeMs: entry.transcribeMs, postProcessMs: entry.postProcessMs,
                  dictionaryFixes: entry.dictionaryFixes, appId: entry.appId, appName: entry.appName, windowTitle: entry.windowTitle)
    }
}

struct CategoryUsage: Sendable, Equatable {
    var category: UsageCategory
    var dictations: Int
    var words: Int
}

struct AppUsage: Sendable, Equatable {
    var name: String
    var dictations: Int
    var words: Int
    /// Calls recorded in the app.
    var meetings: Int = 0
}

struct DayActivity: Sendable, Equatable {
    /// Local calendar day as `YYYY-MM-DD`.
    var date: String
    var dictations: Int
    var words: Int
    var meetings: Int = 0
}

/// One transcribed meeting, as the insights count it: which day, and for a
/// call, which app.
struct InsightMeeting: Sendable, Equatable {
    var started: Date
    var appId: String?
    var appName: String?
}

/// The value a given share of a sample falls under. Percentiles rather than
/// an average, so one slow dictation does not carry the figure.
struct Percentiles: Sendable, Equatable {
    var p50: Int
    var p75: Int
    var p90: Int
    var p95: Int

    init(p50: Int, p75: Int, p90: Int, p95: Int) {
        self.p50 = p50
        self.p75 = p75
        self.p90 = p90
        self.p95 = p95
    }

    /// `nil` for an empty sample.
    init?(_ values: [Int]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        p50 = Self.percentile(sorted, 0.50)
        p75 = Self.percentile(sorted, 0.75)
        p90 = Self.percentile(sorted, 0.90)
        p95 = Self.percentile(sorted, 0.95)
    }

    /// Linear interpolation between the two order statistics the rank falls
    /// between, so the 50th is the usual median.
    private static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = rank - Double(lower)
        return Int((Double(sorted[lower]) + fraction * Double(sorted[upper] - sorted[lower])).rounded())
    }
}

struct InsightsStats: Sendable, Equatable {
    var totalWords: Int
    var totalDictations: Int
    var wordsThisMonth: Int
    /// Words in the previous month up to the same day and time as now, or in
    /// all of it once this month has run longer, so a month in progress is
    /// set against as much of the one before.
    var wordsPreviousMonthSoFar: Int
    /// Spoken words per minute over the dictations that recorded a duration.
    var wordsPerMinute: Double?
    var timedDictations: Int
    /// How much longer typing the timed dictations at `Insights.typingWPM`
    /// would have taken than speaking them, in milliseconds. Negative when
    /// speaking was the slower of the two.
    var timeSavedMs: Int?
    /// Length of one dictation's audio, in milliseconds.
    var audioMs: Percentiles?
    /// Words in one dictation.
    var wordsPerDictation: Percentiles?
    /// Custom-word corrections applied by the fuzzy matcher.
    var dictionaryFixes: Int
    /// Words changed by post-processing where it ran.
    var postProcessFixes: Int
    /// Time the engine took over one dictation, in milliseconds.
    var transcribeMs: Percentiles?
    /// Time spent transcribing as a fraction of the audio's own length, over
    /// the dictations that recorded both.
    var transcribeRealtime: Double?
    /// Time the clean-up took over one dictation, in milliseconds.
    var cleanUpMs: Percentiles?
    var categories: [CategoryUsage]
    /// Dictations with no app recorded, which the categories exclude. Every
    /// entry saved before app attribution shipped counts here.
    var unattributed: Int
    var totalApps: Int
    var topApps: [AppUsage]
    var currentStreak: Int
    var longestStreak: Int
    var activeToday: Bool
    var activity: [DayActivity]
}

/// A calendar day in the caller's calendar: the key for month totals, the
/// activity map and streaks.
struct LocalDay: Hashable, Comparable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 0
        month = components.month ?? 0
        day = components.day ?? 0
    }

    static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// `YYYY-MM-DD`.
    var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The day `count` days away, or `nil` when the calendar cannot place it.
    /// Anchored at noon so a missing or doubled midnight (DST) cannot move the
    /// result onto a neighbouring day.
    func adding(days count: Int, calendar: Calendar) -> LocalDay? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        guard let noon = calendar.date(from: components),
              let shifted = calendar.date(byAdding: .day, value: count, to: noon)
        else { return nil }
        return LocalDay(shifted, calendar: calendar)
    }
}

enum Insights {
    /// Where a dictation went, as the category rules read it.
    private struct Place: Hashable {
        let appId: String?
        let appName: String?
        let windowTitle: String?
    }

    /// Typing speed the spoken rate and the time saved are measured against.
    static let typingWPM = 40.0

    /// Whitespace-separated tokens, as Rust's `str::split_whitespace`: split
    /// on Unicode `White_Space` scalars, empty pieces dropped.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if ModelText.isWhitespace(scalar) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// Number of custom-word corrections between the raw transcript and the
    /// corrected one: each run of changed tokens is one fix.
    static func countDictionaryFixes(raw: String, corrected: String) -> Int {
        if raw.unicodeScalars.elementsEqual(corrected.unicodeScalars) {
            return 0
        }
        switch TokenDiff.hunks(original: raw, edited: corrected) {
        case .some(let hunks): return hunks.count
        // Too long to diff token by token; the texts differ, so count one.
        case .none: return 1
        }
    }

    /// Words a post-processing pass changed: the longer side of every hunk.
    static func countPostProcessFixes(raw: String, processed: String) -> Int {
        if raw.unicodeScalars.elementsEqual(processed.unicodeScalars) {
            return 0
        }
        switch TokenDiff.hunks(original: raw, edited: processed) {
        case .some(let hunks):
            return hunks.reduce(0) { $0 + max($1.removed.count, $1.inserted.count) }
        case .none:
            return max(abs(wordCount(raw) - wordCount(processed)), 1)
        }
    }

    /// From the start of the month before `now`'s to the same day and time,
    /// ending at the start of `now`'s month when the earlier one has fewer
    /// days: on 31 March, all of February.
    static func previousMonthSoFar(now: Date, calendar: Calendar) -> Range<Date>? {
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start,
              let previousMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth)
        else { return nil }
        let elapsed = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: thisMonth, to: now)
        guard let samePoint = calendar.date(byAdding: elapsed, to: previousMonth) else { return nil }
        return previousMonth..<min(samePoint, thisMonth)
    }

    /// A meeting makes its day active, and a call counts against its app;
    /// neither adds words or dictations.
    static func compute(_ rows: [InsightRow], meetings: [InsightMeeting] = [], now: Date = Date(), calendar: Calendar = .current) -> InsightsStats {
        let today = LocalDay(now, calendar: calendar)

        var totalWords = 0
        var wordsThisMonth = 0
        var wordsPreviousMonthSoFar = 0
        var timedWords = 0
        var timedMs = 0
        var timedDictations = 0
        var dictionaryFixes = 0
        var postProcessFixes = 0
        var transcribeTimes: [Int] = []
        var cleanUpTimes: [Int] = []
        var audioLengths: [Int] = []
        var dictationWords: [Int] = []
        var transcribingMs = 0
        var transcribedAudioMs = 0
        var unattributed = 0
        var byCategory: [UsageCategory: (dictations: Int, words: Int)] = [:]
        var byApp: [String: (name: String, dictations: Int, words: Int, meetings: Int)] = [:]
        var byDay: [LocalDay: (dictations: Int, words: Int, meetings: Int)] = [:]
        // Dictations to the same app and window share a category, so the
        // rules run once for each.
        var categoryOf: [Place: UsageCategory?] = [:]

        let thisMonth = (today.year, today.month)
        let previousMonthSoFar = Self.previousMonthSoFar(now: now, calendar: calendar)

        for row in rows {
            let words = row.shownWords ?? wordCount(row.transcript)
            totalWords += words
            dictationWords.append(words)

            let day = LocalDay(row.timestamp, calendar: calendar)
            if (day.year, day.month) == thisMonth {
                wordsThisMonth += words
            } else if previousMonthSoFar?.contains(row.timestamp) == true {
                wordsPreviousMonthSoFar += words
            }
            byDay[day, default: (0, 0, 0)].dictations += 1
            byDay[day, default: (0, 0, 0)].words += words

            if let ms = row.durationMs, ms > 0 {
                timedWords += wordCount(row.transcript)
                timedMs += ms
                timedDictations += 1
                audioLengths.append(ms)
            }

            if let ms = row.transcribeMs, ms > 0 {
                transcribeTimes.append(ms)
                if let audio = row.durationMs, audio > 0 {
                    transcribingMs += ms
                    transcribedAudioMs += audio
                }
            }
            if row.postProcessRequested, let ms = row.postProcessMs, ms > 0 {
                cleanUpTimes.append(ms)
            }

            dictionaryFixes += max(row.dictionaryFixes, 0)
            if row.postProcessRequested, let processed = row.postProcessed {
                postProcessFixes += countPostProcessFixes(raw: row.transcript, processed: processed)
            }

            // A row with nothing known about its destination is not "Other", it
            // is unmeasured. Counting it as a category would report a breakdown
            // the data cannot support.
            let place = Place(appId: row.appId, appName: row.appName, windowTitle: row.windowTitle)
            let category: UsageCategory?
            if let known = categoryOf[place] {
                category = known
            } else {
                category = Category.classify(appId: row.appId, appName: row.appName, windowTitle: row.windowTitle)
                categoryOf[place] = category
            }
            if let category {
                byCategory[category, default: (0, 0)].dictations += 1
                byCategory[category, default: (0, 0)].words += words
            } else {
                unattributed += 1
            }

            let trimmedName = row.appName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = (trimmedName?.isEmpty == false ? trimmedName : nil) ?? row.appId
            if let name = displayName {
                let key: String
                if let id = row.appId, !id.isEmpty {
                    key = id.lowercased()
                } else {
                    key = name.lowercased()
                }
                var entry = byApp[key] ?? (name: name, dictations: 0, words: 0, meetings: 0)
                entry.dictations += 1
                entry.words += words
                byApp[key] = entry
            }
        }

        for meeting in meetings {
            byDay[LocalDay(meeting.started, calendar: calendar), default: (0, 0, 0)].meetings += 1
            guard let name = meeting.appName ?? meeting.appId else { continue }
            let key = (meeting.appId.flatMap { $0.isEmpty ? nil : $0 } ?? name).lowercased()
            var entry = byApp[key] ?? (name: name, dictations: 0, words: 0, meetings: 0)
            entry.meetings += 1
            byApp[key] = entry
        }

        var wordsPerMinute: Double? = nil
        var timeSavedMs: Int? = nil
        if timedMs > 0 {
            let wpm = Double(timedWords) / (Double(timedMs) / 60_000.0)
            if wpm.isFinite {
                wordsPerMinute = wpm
            }
            let typingMs = Double(timedWords) / typingWPM * 60_000.0
            timeSavedMs = Int((typingMs - Double(timedMs)).rounded())
        }

        var transcribeRealtime: Double? = nil
        if transcribedAudioMs > 0 {
            let factor = Double(transcribingMs) / Double(transcribedAudioMs)
            if factor.isFinite {
                transcribeRealtime = factor
            }
        }

        let categories = UsageCategory.allCases.map { category in
            let (dictations, words) = byCategory[category] ?? (0, 0)
            return CategoryUsage(category: category, dictations: dictations, words: words)
        }

        let totalApps = byApp.count
        var topApps = byApp.values.map { AppUsage(name: $0.name, dictations: $0.dictations, words: $0.words, meetings: $0.meetings) }
        // Most used first, by the words the list shows; then by meetings, dictations, then name.
        topApps.sort { a, b in
            if a.words != b.words { return a.words > b.words }
            if a.meetings != b.meetings { return a.meetings > b.meetings }
            if a.dictations != b.dictations { return a.dictations > b.dictations }
            return a.name.unicodeScalars.lexicographicallyPrecedes(b.name.unicodeScalars)
        }

        let (currentStreak, longestStreak) = streaks(byDay, today: today, calendar: calendar)
        let activeToday = byDay[today] != nil

        let activity = byDay.keys.sorted().map { day in
            let (dictations, words, meetings) = byDay[day] ?? (0, 0, 0)
            return DayActivity(date: day.isoString, dictations: dictations, words: words, meetings: meetings)
        }

        return InsightsStats(
            totalWords: totalWords,
            totalDictations: rows.count,
            wordsThisMonth: wordsThisMonth,
            wordsPreviousMonthSoFar: wordsPreviousMonthSoFar,
            wordsPerMinute: wordsPerMinute,
            timedDictations: timedDictations,
            timeSavedMs: timeSavedMs,
            audioMs: Percentiles(audioLengths),
            wordsPerDictation: Percentiles(dictationWords),
            dictionaryFixes: dictionaryFixes,
            postProcessFixes: postProcessFixes,
            transcribeMs: Percentiles(transcribeTimes),
            transcribeRealtime: transcribeRealtime,
            cleanUpMs: Percentiles(cleanUpTimes),
            categories: categories,
            unattributed: unattributed,
            totalApps: totalApps,
            topApps: topApps,
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            activeToday: activeToday,
            activity: activity
        )
    }


    /// `(current, longest)` runs of consecutive active days, a day with a
    /// dictation or a meeting. The current streak is still alive on a day with
    /// nothing yet, so it is counted back from yesterday when today is empty.
    static func streaks(
        _ byDay: [LocalDay: (dictations: Int, words: Int, meetings: Int)],
        today: LocalDay,
        calendar: Calendar
    ) -> (current: Int, longest: Int) {
        var longest = 0
        var run = 0
        var previous: LocalDay? = nil
        for day in byDay.keys.sorted() {
            if let next = previous?.adding(days: 1, calendar: calendar), next == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }

        var cursor: LocalDay?
        if byDay[today] != nil {
            cursor = today
        } else if let yesterday = today.adding(days: -1, calendar: calendar), byDay[yesterday] != nil {
            cursor = yesterday
        } else {
            cursor = nil
        }
        var current = 0
        while let day = cursor {
            if byDay[day] == nil {
                break
            }
            current += 1
            cursor = day.adding(days: -1, calendar: calendar)
        }
        return (current, longest)
    }
}
