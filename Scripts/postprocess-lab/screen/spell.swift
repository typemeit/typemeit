import AppKit
// Is NSSpellChecker's verdict on names stable, and does automatic language
// identification change it?
@MainActor func run() {
    let c = NSSpellChecker.shared
    let words = ["tomasz", "wieczorek", "kavu", "kavuu", "zentryx", "raghunathan", "priya", "tomash", "cavu", "maxxo", "blebbered"]
    print("automaticallyIdentifiesLanguages default:", c.automaticallyIdentifiesLanguages, "language:", c.language())
    for auto in [true, false] {
        c.automaticallyIdentifiesLanguages = auto
        if !auto { _ = c.setLanguage("en_GB") }
        var line = "auto=\(auto): "
        for w in words {
            var knownCount = 0
            for _ in 0..<20 where c.checkSpelling(of: w, startingAt: 0).location == NSNotFound { knownCount += 1 }
            line += "\(w) \(knownCount)/20  "
        }
        print(line)
    }
}
await MainActor.run { run() }
