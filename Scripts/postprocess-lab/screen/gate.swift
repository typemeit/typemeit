import AppKit
import Foundation
// usage: screengate <cases.json> <history.json>   (env MERGE=n screens merged)
// The variant's own screen-term gate on real dictations paired with unrelated eval screens.
struct Case: Decodable { let screen: [String]? }
struct Entry: Decodable { let transcript: String }
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let history = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
let merge = Int(ProcessInfo.processInfo.environment["MERGE"] ?? "1")!
let lines = cases.compactMap(\.screen)
let screens: [[String]] = await MainActor.run { stride(from: 0, to: lines.count, by: merge).map { ScreenContext.terms(from: lines[$0..<min($0 + merge, lines.count)].flatMap { $0 }, excluding: []) } }
var fired = 0, pairs = 0, dictations = 0
var byTerm: [String: Int] = [:]
for h in history {
    let fused = h.transcript
    let unknown = await ScreenContext.unknownWords(in: fused)
    let keys = fused.split(whereSeparator: \.isWhitespace).map { CustomWordMatcher.letters(String($0)) }
    var any = false
    for terms in screens {
        pairs += 1
        if let t = PostProcessor.soundsLikeScreenTerm(keys, terms, unknownWords: unknown) { fired += 1; any = true; byTerm[t, default: 0] += 1 }
    }
    if any { dictations += 1 }
}
print("screens: \(screens.map(\.count)) terms")
print(String(format: "false fires %d/%d pairs (%.1f%%); %d/%d dictations fire with some screen", fired, pairs, 100 * Double(fired) / Double(pairs), dictations, history.count))
print(byTerm.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
