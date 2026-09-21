import Foundation

/// Where the two Macs meet. The worker behind this is in `worker.js`;
/// `TYPEMEIT_SHARE_HOST` points a debug build at one running somewhere else.
enum ShareService {
    static var host: String {
        let named = ProcessInfo.processInfo.environment["TYPEMEIT_SHARE_HOST"]
        return (named?.isEmpty == false ? named : nil) ?? "typeme.it"
    }

    static func room(_ id: String) -> URL? { URL(string: "wss://\(host)/share/room/\(id)") }
}

/// Frames go through typeme.it, which passes them between the two Macs in
/// the room the pairing code names.
///
/// What passes through is sealed: the key is derived partly from the code,
/// and what the server is given is the code's hash. So it moves bytes it
/// cannot read and could not learn to read. That is not the same as the
/// notes never being there at all, which is what the WebRTC transport is for
/// and why it is coming back.
///
/// The server's own messages arrive as text and a frame from the other Mac
/// arrives as binary, which is the whole of the telling apart: the room
/// refuses to pass text between Macs, so the other end cannot pose as the
/// server by sending something that reads like one of its messages.
@MainActor
final class ShareRelay: ShareTransport {
    var onOpen: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((String?) -> Void)?

    private let room: String
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var open = false

    init(room: String) {
        self.room = room
    }

    func start() {
        guard let url = ShareService.room(room) else {
            close("could not reach \(ShareService.host)")
            return
        }
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        read()
    }

    func send(_ data: Data) {
        guard !closed, open else { return }
        task?.send(.data(data)) { error in
            guard let error else { return }
            Log.sharing.error("Could not send a frame: \(error.localizedDescription)")
        }
    }

    func close() {
        close(nil)
    }

    private func close(_ reason: String?) {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onClose?(reason)
    }

    /// What the room itself says. Nothing a Mac sends can arrive this way.
    private struct Word: Codable {
        var t: String
        /// How many are in the room, counting this Mac.
        var peers: Int?
    }

    private func read() {
        task?.receive { [weak self] result in
            // Only the bytes cross; the message itself stays here.
            var text: String?
            var binary: Data?
            var failure: String?
            switch result {
            case .success(.string(let string)):
                text = string
            case .success(.data(let data)):
                binary = data
            case .success:
                break
            case .failure(let error):
                failure = error.localizedDescription
            }
            let (said, frame, reason) = (text, binary, failure)
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let reason { self.close(reason); return }
                if let said { self.heard(said) }
                if let frame { self.onData?(frame) }
                self.read()
            }
        }
    }

    private func heard(_ text: String) {
        guard let data = text.data(using: .utf8),
              let word = try? JSONDecoder().decode(Word.self, from: data) else { return }
        switch word.t {
        case "room":
            if (word.peers ?? 1) >= 2 { opened() }
        case "peer":
            opened()
        case "gone":
            // Before the notes are through this is the share; after it, the
            // frames that mattered have already landed and whoever is left
            // finishes on their own.
            close(open ? nil : "the other mac left")
        default:
            break
        }
    }

    private func opened() {
        guard !open, !closed else { return }
        open = true
        onOpen?()
    }
}
