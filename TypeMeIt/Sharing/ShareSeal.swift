import CommonCrypto
import CryptoKit
import Foundation

/// Sealing the notes for one drop.
///
/// There is no handshake here to agree a key with, because there is nobody on
/// the other end yet — the notes are sealed, left, and collected later. So the
/// key comes from the ten characters of the code that never leave the two
/// people, stretched by PBKDF2 so that guessing at them costs something.
///
/// What the server holds is the sealed bytes and the eight characters that
/// name them. Those eight say nothing about the other ten, so holding the
/// drop is not a way in.
enum ShareSeal {
    /// A blob starts with these, so a file that is not one of ours is turned
    /// away before anything is decrypted.
    static let magic = Data("tmi1".utf8)
    static let saltBytes = 16
    /// OWASP's floor for PBKDF2-SHA256, and about a third of a second on an
    /// Apple silicon Mac — unnoticeable once per share, ruinous to an
    /// attacker working through fifty bits of secret.
    static let rounds: UInt32 = 600_000

    enum Failure: Error, Equatable {
        case notOurs
        case cannotSeal
        /// The wrong code, or bytes that were interfered with. The two are
        /// deliberately not told apart: which it was is not the user's
        /// problem and saying would be telling an attacker they were close.
        case cannotOpen
    }

    /// `magic` · salt · sealed. The salt is in the clear, as a salt is.
    nonisolated static func seal(_ payload: SharePayload, secret: String) throws -> Data {
        var salt = Data(count: saltBytes)
        for i in 0..<saltBytes { salt[i] = UInt8.random(in: .min ... .max) }
        guard let key = key(secret: secret, salt: salt),
              let body = try? SharePayload.encoder.encode(payload),
              let box = try? ChaChaPoly.seal(body, using: key) else { throw Failure.cannotSeal }
        return magic + salt + box.combined
    }

    nonisolated static func open(_ blob: Data, secret: String) throws -> SharePayload {
        let head = magic.count + saltBytes
        guard blob.count > head, blob.prefix(magic.count) == magic else { throw Failure.notOurs }
        let salt = Data(blob.dropFirst(magic.count).prefix(saltBytes))
        let sealed = Data(blob.dropFirst(head))
        guard let key = key(secret: secret, salt: salt),
              let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let body = try? ChaChaPoly.open(box, using: key),
              let payload = try? SharePayload.decoder.decode(SharePayload.self, from: body) else {
            throw Failure.cannotOpen
        }
        return payload
    }

    /// PBKDF2-SHA256. CryptoKit has no password-based derivation, so this is
    /// CommonCrypto's.
    nonisolated static func key(secret: String, salt: Data) -> SymmetricKey? {
        var derived = [UInt8](repeating: 0, count: 32)
        let secretLength = secret.utf8.count
        let status = salt.withUnsafeBytes { saltBytes -> Int32 in
            guard let saltBase = saltBytes.bindMemory(to: UInt8.self).baseAddress else {
                return Int32(kCCParamError)
            }
            return CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                secret, secretLength,
                saltBase, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                rounds,
                &derived, derived.count
            )
        }
        guard status == Int32(kCCSuccess) else { return nil }
        return SymmetricKey(data: Data(derived))
    }
}
