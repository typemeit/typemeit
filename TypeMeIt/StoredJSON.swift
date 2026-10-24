import Foundation

/// The JSON the app's files are written in: ISO-8601 dates, sorted keys.
/// `typemeit-mcp` compiles this file too, so it reads `history.json` and
/// `meeting.json` with the decoder that matches the encoder that wrote them.
enum StoredJSON {
    /// A whole file, such as `history.json` or `meeting.json`.
    static let fileEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// One value on one line, such as a line of `question-log.jsonl`.
    static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
