import Foundation
import FoundationModels

/// Runs the made-up meetings in cases.json through MeetingSummary as it
/// ships: the summary, then the title written from it. A summary fails when
/// it runs over `MeetingSummary.maxSentences` or `maxWords`, names a
/// "Speaker" placeholder, misses every alternative in one of its `mention`
/// groups, or says anything in `avoid`. A title fails outside
/// `MeetingSummary.titleWords`, when it names a speaker other than You, or
/// on its own `mention` and `avoid`. Words match case-insensitively from a word start, so
/// "price" also finds "prices". A case with `wish` is reported but never
/// fails the run.
struct Checks: Decodable {
    let mention: [[String]]
    let avoid: [String]
}

struct Case: Decodable {
    let name: String
    let turns: [MeetingSummary.Turn]
    let summary: Checks
    let title: Checks
    let wish: String?
}

struct Result: Encodable {
    let name: String
    let words: Int
    let summary: String?
    let title: String?
    let problems: [String]
    let wish: String?
}

@main
struct Eval {
    static func says(_ text: String, _ phrase: String) -> Bool {
        text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: phrase), options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What `text` gets wrong against `checks`, one line each.
    static func problems(_ text: String, _ checks: Checks) -> [String] {
        checks.mention.filter { group in !group.contains { says(text, $0) } }.map { "names none of \($0.joined(separator: " / "))" }
            + checks.avoid.filter { says(text, $0) }.map { "says \($0)" }
    }

    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("cases.json")))
        guard case .available = SystemLanguageModel.default.availability else { print("Apple Intelligence is not available on this Mac"); exit(2) }
        var results: [Result] = []
        for c in cases {
            let summary = await MeetingSummary.summarise(c.turns)
            let title = await MeetingSummary.title(summary: summary, turns: c.turns)
            var found: [String] = []
            if let summary {
                let sentences = MeetingSummary.sentenceCount(summary)
                let words = summary.split(separator: " ").count
                if sentences > MeetingSummary.maxSentences { found.append("summary: \(sentences) sentences") }
                if words > MeetingSummary.maxWords { found.append("summary: \(words) words") }
                if says(summary, "Speaker") { found.append("summary: says Speaker") }
                found += problems(summary, c.summary).map { "summary: \($0)" }
            } else {
                found.append("no summary")
            }
            if let title {
                let words = title.split(separator: " ").count
                if !MeetingSummary.titleWords.contains(words) { found.append("title: \(words) words") }
                let names = Set(c.turns.map(\.speaker)).subtracting(["You"]).flatMap { $0.split(separator: " ").map(String.init) }
                found += names.filter { says(title, $0) }.map { "title: names \($0)" }
                found += problems(title, c.title).map { "title: \($0)" }
            } else {
                found.append("no title")
            }
            let words = c.turns.reduce(0) { $0 + $1.text.split(separator: " ").count }
            let mark = c.wish != nil ? (found.isEmpty ? "WISH  granted" : "WISH  not yet") : (found.isEmpty ? "PASS" : "FAIL")
            print("\(mark)  \(c.name) (\(words) words)\n      title:   \(title ?? "none")\n      summary: \(summary ?? "none")")
            for problem in found { print("      ✗ \(problem)") }
            results.append(Result(name: c.name, words: words, summary: summary, title: title, problems: found, wish: c.wish))
        }
        let counted = results.filter { $0.wish == nil }
        let passed = counted.filter(\.problems.isEmpty).count
        print("\n\(passed)/\(counted.count) passed")
        let wishes = results.filter { $0.wish != nil }
        if !wishes.isEmpty { print("wish list: \(wishes.filter(\.problems.isEmpty).count)/\(wishes.count) granted") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(results).write(to: dir.appendingPathComponent("result.json"))
        exit(passed == counted.count ? 0 : 1)
    }
}
