import Foundation

/// The code one person hands to the other. It is the whole of the pairing:
/// no account, no directory, nothing remembered between shares.
///
/// It is two halves doing two jobs, and the split is the point. The first
/// eight characters name the drop and are given to the server. The last ten
/// are the secret the notes are sealed with and are never sent anywhere —
/// they go from one person to the other and nowhere else.
///
/// Derived one from the other, they would not be worth splitting: whoever
/// holds the name could work back to the secret by trying names, and trying
/// names is fast. Drawn separately, the name tells you nothing about the
/// secret, and the only way at the notes is the ten characters nobody but
/// the two people ever saw.
enum ShareCode {
    /// No I, L, O, 0 or 1. A code gets read off one screen and typed into
    /// another, and those are the characters that go wrong.
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    /// What the server is told.
    static let nameLength = 8
    /// What it is not. Ten characters of thirty-one is a shade under fifty
    /// bits, and `ShareSeal` puts six hundred thousand rounds between a guess
    /// and a key, which is far past what anyone will sit through.
    static let secretLength = 10

    struct Pickup: Equatable, Sendable {
        /// Names the drop. Goes to the server.
        let name: String
        /// Opens it. Goes to the other person and nowhere else.
        let secret: String

        var code: String { name + secret }
    }

    static func make() -> Pickup {
        Pickup(name: draw(nameLength), secret: draw(secretLength))
    }

    private static func draw(_ count: Int) -> String {
        String((0..<count).map { _ in alphabet.randomElement()! })
    }

    /// A typed code split back into its halves, or nil when it is not one.
    /// Case, spaces and the dashes the app shows are all forgiven.
    static func tidy(_ typed: String) -> Pickup? {
        let bare = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard bare.count == nameLength + secretLength,
              bare.allSatisfy({ alphabet.contains($0) }) else { return nil }
        let split = bare.index(bare.startIndex, offsetBy: nameLength)
        return Pickup(name: String(bare[..<split]), secret: String(bare[split...]))
    }

    /// How a code is shown: in fours, which is how people read them back and
    /// how they survive being retyped.
    static func spaced(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { start in
            let from = code.index(code.startIndex, offsetBy: start)
            let to = code.index(from, offsetBy: min(4, code.count - start))
            return String(code[from..<to])
        }.joined(separator: "-")
    }
}
