// usage: see run.sh (G5 and later).
import AppKit
import Foundation

// What G5's code replacement does to real dictations: screen terms from unrelated
// eval screens (so every replacement is false), and the author's custom words
// through the hint path (replacements printed for review, not stored).
struct Case: Decodable { let screen: [String]? }
struct Entry: Decodable { let transcript: String }
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let history = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
let custom = CommandLine.arguments.count > 3 ? CommandLine.arguments[3].split(separator: ",").map(String.init) : []
let merge = Int(ProcessInfo.processInfo.environment["MERGE"] ?? "4")!
let lines = cases.compactMap(\.screen)
let screens: [[String]] = await MainActor.run { stride(from: 0, to: lines.count, by: merge).map { ScreenContext.terms(from: lines[$0..<min($0 + merge, lines.count)].flatMap { $0 }, excluding: []) } }

func changed(_ a: String, _ b: String) -> String {
    let x = a.split(separator: " ").map(String.init), y = b.split(separator: " ").map(String.init)
    return "\(x.filter { !y.contains($0) }.joined(separator: " ")) → \(y.filter { !x.contains($0) }.joined(separator: " "))"
}
var screenFixes: [String] = [], customFixes: [String] = []
var screenDictations = 0
for h in history {
    let unknown = await ScreenContext.unknownWords(in: h.transcript)
    guard !unknown.isEmpty else { continue }
    let words = h.transcript.split(whereSeparator: \.isWhitespace).map { CustomWordMatcher.Word(text: String($0), confidence: nil) }
    var any = false
    for terms in screens {
        let out = CustomWordMatcher.apply(words, terms: terms.map { CustomWordMatcher.Term($0) }, only: unknown)
        if out.fixes > 0 { any = true; screenFixes.append(changed(h.transcript, out.text)) }
    }
    if any { screenDictations += 1 }
    let confident = h.transcript.split(whereSeparator: \.isWhitespace).map { CustomWordMatcher.Word(text: String($0), confidence: 1) }
    let hints = CustomWordMatcher.apply(confident, terms: custom).hints
    let settled = hints.filter { $0.heard.split(separator: " ").contains { unknown.contains(CustomWordMatcher.letters(String($0))) } }
    if !settled.isEmpty { customFixes.append(changed(h.transcript, CustomWordMatcher.applyHints(settled, to: h.transcript))) }
}
print("screens: \(screens.map(\.count)) terms; \(history.count) dictations")
print("screen-term replacements: \(screenFixes.count) in \(screenDictations) dictations (all false: the screens are unrelated)")
if ProcessInfo.processInfo.environment["SHOW"] == "1" { for f in screenFixes { print("   \(f)") } }
print("custom-word hints settled in code: \(customFixes.count)")
if ProcessInfo.processInfo.environment["SHOW"] == "1" { for f in customFixes { print("   \(f)") } }
