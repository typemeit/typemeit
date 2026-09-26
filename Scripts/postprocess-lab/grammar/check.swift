import AppKit

// Asks the system spell and grammar checker about each line of stdin (or the given strings)
// and prints every grammar issue with its suggested corrections, plus autocorrections.
func check(_ text: String) -> [String] {
    let checker = NSSpellChecker.shared
    let types: NSTextCheckingTypes = NSTextCheckingResult.CheckingType.grammar.rawValue | NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.correction.rawValue
    let results = checker.check(text, range: NSRange(location: 0, length: (text as NSString).length), types: types, options: [:], inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
    var out: [String] = []
    for r in results {
        let span = (text as NSString).substring(with: r.range)
        switch r.resultType {
        case .grammar:
            for d in r.grammarDetails ?? [] {
                let fixes = (d["NSGrammarCorrections"] as? [String]) ?? []
                let desc = (d["NSGrammarUserDescription"] as? String) ?? ""
                var sub = span
                if let gr = d["NSGrammarRange"] as? NSValue {
                    let rr = gr.rangeValue
                    sub = ((span as NSString).substring(with: NSRange(location: min(rr.location, (span as NSString).length), length: min(rr.length, (span as NSString).length - min(rr.location, (span as NSString).length)))))
                }
                out.append("grammar '\(sub)' → \(fixes) (\(desc.prefix(70)))")
            }
        case .spelling:
            let guesses = checker.guesses(forWordRange: r.range, in: text, language: nil, inSpellDocumentWithTag: 0) ?? []
            out.append("spelling '\(span)' → \(guesses.prefix(3))")
        case .correction:
            out.append("autocorrect '\(span)' → \(r.replacementString ?? "")")
        default: break
        }
    }
    return out
}

let inputs = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : readLines()
func readLines() -> [String] { var a: [String] = []; while let l = readLine() { a.append(l) }; return a }
for t in inputs {
    let r = check(t)
    print("\(r.isEmpty ? "  clean" : "FLAGGED")  \(t.prefix(90))")
    for x in r { print("          \(x)") }
}
