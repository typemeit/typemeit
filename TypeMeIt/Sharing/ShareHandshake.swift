import CryptoKit
import Foundation

/// The agreement two Macs reach before any note moves.
///
/// Each end makes a throwaway X25519 key pair, sends the public half, and
/// derives the same secret from the other's. That alone would be wide open to
/// anyone on the network who can answer first, so the derivation also yields
/// four digits — the same four on both Macs, and different ones if a third
/// party sat in the middle. Both users are shown them, and the notes only go
/// once the person receiving has said yes to the digits they can see on the
/// sending Mac. The digits are the authentication; the key agreement on its
/// own is not.
enum ShareHandshake {
    private static let keyInfo = Data("type me it share v1 key".utf8)
    private static let codeInfo = Data("type me it share v1 code".utf8)

    struct Agreement: Sendable {
        let key: SymmetricKey
        /// The four digits both ends show.
        let code: String
    }

    enum Failure: Error, Equatable {
        case badKey
        case cannotSeal
        case cannotOpen
    }

    static func agree(ours: Curve25519.KeyAgreement.PrivateKey, theirs: Data) throws -> Agreement {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs) else {
            throw Failure.badKey
        }
        guard let secret = try? ours.sharedSecretFromKeyAgreement(with: peer) else {
            throw Failure.badKey
        }
        let salt = transcript(ours.publicKey.rawRepresentation, theirs)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: keyInfo, outputByteCount: 32)
        let digits = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: codeInfo, outputByteCount: 4)
        return Agreement(key: key, code: code(from: digits))
    }

    /// Both public keys in a fixed order, so the two ends derive the same key
    /// whichever of them dialled.
    static func transcript(_ a: Data, _ b: Data) -> Data {
        a.lexicographicallyPrecedes(b) ? a + b : b + a
    }

    /// Four digits, leading zeros kept: 0007 reads as a code, 7 reads as a
    /// mistake.
    static func code(from key: SymmetricKey) -> String {
        let n = key.withUnsafeBytes { bytes in bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        return String(format: "%04u", n % 10_000)
    }

    static func seal(_ payload: SharePayload, with key: SymmetricKey) throws -> Data {
        guard let body = try? ShareWire.encoder.encode(payload),
              let box = try? ChaChaPoly.seal(body, using: key) else { throw Failure.cannotSeal }
        return box.combined
    }

    static func open(_ sealed: Data, with key: SymmetricKey) throws -> SharePayload {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let body = try? ChaChaPoly.open(box, using: key),
              let payload = try? ShareWire.decoder.decode(SharePayload.self, from: body) else {
            throw Failure.cannotOpen
        }
        return payload
    }
}
