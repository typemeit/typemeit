import Foundation

enum Transcriber {
    struct Word: Equatable, Codable {
        let text: String
        let confidence: Float
        let start: Duration
        let end: Duration
    }
}
enum Meeting { enum Echo { case notMeasured, clean, affected } }
extension Duration {
    var milliseconds: Int { Int(components.seconds * 1000) + Int(components.attoseconds / 1_000_000_000_000_000) }
}
