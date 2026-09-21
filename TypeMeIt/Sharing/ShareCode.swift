import CryptoKit
import Foundation

/// The code one person reads out and the other types in.
///
/// It is the whole of the pairing: there is no account, no directory and
/// nothing remembered between shares. A code is made for one share, names the
/// room the two Macs meet in, and is worth nothing once that room has closed.
enum ShareCode {
    /// No I, L, O, 0 or 1. A code gets read off one screen and typed into
    /// another, often out loud, and those are the characters that go wrong.
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let length = 8

    /// Eight characters out of thirty-one is a little under forty bits, which
    /// is far more than anyone will guess against a room that closes after ten
    /// minutes and refuses a third caller. It is not enough to stand alone
    /// against someone who records a share and works on it afterwards, which
    /// is why the four digits are checked as well.
    static func make() -> String {
        String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// A typed code as the room name expects it, or nil when it is not one.
    /// Case, spaces and the dash the app shows are all forgiven.
    static func tidy(_ typed: String) -> String? {
        let bare = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard bare.count == length, bare.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return bare
    }

    /// How a code is shown: in two halves, which is how people read them back.
    static func spaced(_ code: String) -> String {
        guard code.count == length else { return code }
        let half = code.index(code.startIndex, offsetBy: length / 2)
        return code[..<half] + "-" + code[half...]
    }

    /// The room the two Macs meet in. The server is given this and never the
    /// code, so it can tell one pair of Macs from another without being able
    /// to join them.
    static func room(for code: String) -> String {
        SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
