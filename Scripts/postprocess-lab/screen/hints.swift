// usage: compile with -parse-as-library against a variant's sources; argument: a history replay set with customWords and aliases.
import Foundation
// Which custom-word hints remain after G5 settles non-dictionary ones (private: counts only are stored).
struct C: Decodable { let input: String; let customWords: [String]; let aliases: [String: [String]]? }
@main struct H { static func main() async throws {
    let cases = try JSONDecoder().decode([C].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    var counts: [String: Int] = [:]
    for c in cases {
        let words = c.input.split(whereSeparator: \.isWhitespace).map { CustomWordMatcher.Word(text: String($0), confidence: 1) }
        let m = CustomWordMatcher.apply(words, terms: c.customWords.map { CustomWordMatcher.Term($0, aliases: c.aliases?[$0] ?? []) })
        guard !m.hints.isEmpty else { continue }
        let unknown = await ScreenContext.unknownWords(in: c.input)
        for h in m.hints where !h.heard.split(separator: " ").contains(where: { unknown.contains(CustomWordMatcher.letters(String($0))) }) {
            counts["\(h.heard.lowercased()) → \(h.term)", default: 0] += 1
        }
    }
    for (k, v) in counts.sorted(by: { $0.value > $1.value }) { print(v, k) }
} }
