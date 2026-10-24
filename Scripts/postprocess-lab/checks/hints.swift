import Foundation
struct C: Decodable { let input: String; let customWords: [String]? }
let cases = try! JSONDecoder().decode([C].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var counts: [String: Int] = [:]
for c in cases {
    let words = c.input.split(whereSeparator: \.isWhitespace).map { CustomWordMatcher.Word(text: String($0), confidence: 1) }
    let m = CustomWordMatcher.apply(words, terms: (c.customWords ?? []).map { CustomWordMatcher.Term($0) })
    for h in m.hints { counts["\(h.heard) → \(h.term)", default: 0] += 1 }
}
for (k, v) in counts.sorted(by: { $0.value > $1.value }) { print(v, k) }
