import Foundation

/// One note on its way to another Mac. Only the text and when it was said:
/// not the app it was typed into, not the window title, not the audio, and
/// not what the engine heard before clean-up. A note that arrives carries
/// nothing the sender did not mean to hand over.
struct SharedNote: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var timestamp: Date
    var text: String
}

/// What travels sealed once both ends have agreed on a key.
struct SharePayload: Codable, Equatable, Sendable {
    var notes: [SharedNote]
}

/// A message on the wire. One struct rather than an enum with associated
/// values, because it crosses versions: a field a build does not know about
/// decodes to nil instead of failing the whole frame.
struct ShareFrame: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Opens the conversation: an ephemeral public key and a name to
        /// show. Both ends send one before anything else.
        case hello
        /// The sender says how many notes are coming, so the other end can
        /// ask its user before any of them are decrypted.
        case offer
        /// The receiver's answer to the offer.
        case decision
        /// The sealed payload.
        case notes
    }

    var kind: Kind
    /// `hello`: the raw 32 bytes of an ephemeral X25519 public key.
    var key: Data?
    /// `hello`: what the other end should call this Mac.
    var name: String?
    /// `offer`: how many notes are coming. A preview for the prompt only —
    /// the list the receiver is shown is built from the sealed payload, so a
    /// peer that lies here changes the wording and nothing else.
    var count: Int?
    /// `decision`: whether the receiver took the offer.
    var accepted: Bool?
    /// `notes`: the sealed payload.
    var sealed: Data?
}

/// Length-prefixed JSON: four bytes big-endian, then that many bytes of
/// frame. TCP hands over whatever has arrived, so the length is what says
/// where one frame ends and the next begins.
enum ShareWire {
    /// Notes are text, and half a megabyte of it is more than anyone shares
    /// in one go. The cap is also what keeps an encoded frame inside the one
    /// megabyte a websocket message is allowed, and a frame larger than this
    /// is not one of ours anyway — reading it would mean holding it in
    /// memory first.
    static let maxFrame = 512 * 1024

    enum Failure: Error, Equatable {
        case tooLarge(Int)
        case malformed
    }

    static func encode(_ frame: ShareFrame) throws -> Data {
        let body = try encoder.encode(frame)
        guard body.count <= maxFrame else { throw Failure.tooLarge(body.count) }
        var out = Data(capacity: body.count + 4)
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: UInt32(body.count) >> UInt32(shift)))
        }
        out.append(body)
        return out
    }

    /// The next whole frame, taken off the front of `buffer`. Nil while the
    /// bytes for one have not all arrived; `buffer` is left untouched then,
    /// so the caller can read more and ask again.
    static func decode(from buffer: inout Data) throws -> ShareFrame? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(Int(0)) { ($0 << 8) | Int($1) }
        guard length <= maxFrame else { throw Failure.tooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }
        // Rebuilt rather than trimmed in place: a Data slice keeps the
        // indices of what it was cut from, and the next read would be
        // measuring against the wrong start.
        let body = Data(buffer.dropFirst(4).prefix(length))
        buffer = Data(buffer.dropFirst(4 + length))
        do { return try decoder.decode(ShareFrame.self, from: body) } catch { throw Failure.malformed }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
