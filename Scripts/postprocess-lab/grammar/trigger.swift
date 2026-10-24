import AppKit

// Grammar-only check of each line of a JSON string array: prints flagged items and timing.
let texts = try! JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())
let checker = NSSpellChecker.shared
var flagged = 0, times: [Double] = []
for t in texts {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let rs = checker.check(t, range: NSRange(location: 0, length: (t as NSString).length), types: NSTextCheckingResult.CheckingType.grammar.rawValue, options: [:], inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
    times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    let issues = rs.flatMap { r in (r.grammarDetails ?? []).map { d -> String in
        let desc = (d["NSGrammarUserDescription"] as? String) ?? ""
        let fixes = (d["NSGrammarCorrections"] as? [String]) ?? []
        return "\(desc.prefix(60)) → \(fixes.prefix(2))"
    } }
    if !issues.isEmpty { flagged += 1; print("FLAG  \(t.prefix(100))\n      \(issues.joined(separator: " | "))") }
}
times.sort()
print("flagged \(flagged)/\(texts.count); p50 \(String(format: "%.2f", times[times.count / 2])) ms, max \(String(format: "%.1f", times.last!)) ms")
