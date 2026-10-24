// usage: see run.sh.
import AppKit
import Foundation

// usage: screencheck <cases.json> <history.json> [realistic-cases.json]
// Pairs every real dictation with every eval screen (unrelated, so any match is
// false) and counts how often variants of the screen-term rule fire; then checks
// the same rules on the eval's own screen cases, where a match is wanted.
struct Case: Decodable { let input: String; let screen: [String]?; let customWords: [String]?; let expected: String }
struct Entry: Decodable { let transcript: String }
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let history = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
let realistic = CommandLine.arguments.count > 3 ? try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) : []

let checker = await MainActor.run { NSSpellChecker.shared }
var known: [String: Bool] = [:]
@MainActor func isKnown(_ w: String) -> Bool {
    if let k = known[w] { return k }
    let k = checker.checkSpelling(of: w, startingAt: 0).location == NSNotFound
    known[w] = k; return k
}

struct Rule { let name: String; let sim: Double; let ratio: Double; let unknownOnly: Bool }
let rules = [
    Rule(name: "current (0.7, ratio 0.6)", sim: 0.7, ratio: 0.6, unknownOnly: false),
    Rule(name: "0.85, ratio 0.7", sim: 0.85, ratio: 0.7, unknownOnly: false),
    
]

@MainActor func fires(_ rule: Rule, _ text: String, _ terms: [String]) -> String? {
    let words = text.split(whereSeparator: \.isWhitespace).map { CustomWordMatcher.letters(String($0)) }
    let present = Set(words)
    for term in terms {
        let letters = CustomWordMatcher.letters(term)
        guard letters.count >= CustomWordMatcher.minFuzzyTermLetters, !present.contains(letters) else { continue }
        let termKey = CustomWordMatcher.soundKey(CustomWordMatcher.compact(letters))
        for start in words.indices {
            for length in 1...3 where start + length <= words.count {
                let run = words[start..<(start + length)]
                guard !run.allSatisfy({ CustomWordMatcher.stopWords.contains($0) }) else { continue }
                let a = CustomWordMatcher.compact(run.joined()), b = CustomWordMatcher.compact(letters)
                guard !a.isEmpty, Double(min(a.count, b.count)) / Double(max(a.count, b.count)) >= rule.ratio else { continue }
                guard CustomWordMatcher.similarity(CustomWordMatcher.soundKey(a), termKey) >= rule.sim else { continue }
                if rule.unknownOnly, !run.contains(where: { !$0.isEmpty && $0.first!.isLetter && !isKnown($0) }) { continue }
                return "\(run.joined(separator: " ")) → \(term)"
            }
        }
    }
    return nil
}

let merge = Int(ProcessInfo.processInfo.environment["MERGE"] ?? "1")!
let screenLines = cases.compactMap(\.screen)
let screens: [[String]] = await MainActor.run {
    stride(from: 0, to: screenLines.count, by: merge).map { i in
        ScreenContext.terms(from: screenLines[i..<min(i + merge, screenLines.count)].flatMap { $0 }, excluding: [])
    }
}
print("\(screens.count) screens, terms per screen: \(screens.map(\.count))")
for rule in rules {
    let (pairs, fired, dictations): (Int, Int, Int) = await MainActor.run {
        var pairs = 0, fired = 0, dictations = 0
        for h in history {
            var any = false
            for terms in screens { pairs += 1; if fires(rule, h.transcript, terms) != nil { fired += 1; any = true } }
            if any { dictations += 1 }
        }
        return (pairs, fired, dictations)
    }
    let wanted: [String] = await MainActor.run {
        (cases + realistic).compactMap { c in
            guard let screen = c.screen else { return nil }
            let terms = ScreenContext.terms(from: screen, excluding: c.customWords ?? [])
            return "\(fires(rule, c.input, terms) ?? "-")   [\(c.input.prefix(40))]"
        }
    }
    print(String(format: "%@: false fires %d/%d pairs (%.1f%%), %d/%d dictations fire with some screen", rule.name, fired, pairs, 100 * Double(fired) / Double(pairs), dictations, history.count))
    if ProcessInfo.processInfo.environment["SHOW"] == "1" { for w in wanted { print("     eval: \(w)") } }
}
