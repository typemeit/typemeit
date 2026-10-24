import Foundation

/// "1 word", "2 words": a count with the noun agreeing. Nouns that do not
/// take a plain s pass their plural explicitly.
func counted(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(n.formatted()) \(n == 1 ? singular : plural ?? singular + "s")"
}
