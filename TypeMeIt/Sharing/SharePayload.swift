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

/// What gets sealed and dropped off. The sender's name is inside the seal
/// rather than beside it: it is there so the person collecting knows who
/// left it, which is not a reason for anyone else to be able to read it.
struct SharePayload: Codable, Equatable, Sendable {
    var from: String
    var notes: [SharedNote]

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
