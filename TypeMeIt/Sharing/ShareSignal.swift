import Foundation

/// Where the two Macs are introduced. The worker behind this is in
/// `worker.js`; `TYPEMEIT_SHARE_HOST` points a debug build at one running
/// somewhere else.
enum ShareService {
    static var host: String {
        let named = ProcessInfo.processInfo.environment["TYPEMEIT_SHARE_HOST"]
        return (named?.isEmpty == false ? named : nil) ?? "typeme.it"
    }

    static var ice: URL? { URL(string: "https://\(host)/share/ice") }
    static func room(_ id: String) -> URL? { URL(string: "wss://\(host)/share/room/\(id)") }
}

/// The addresses to try, asked for once per share.
enum ShareIce {
    private struct Answer: Codable { var iceServers: [ShareIceServer] }

    /// Cloudflare's public STUN, which is what the worker offers when no
    /// relay has been set up. Used directly when the worker cannot be
    /// reached at all, so a share on one network still has a chance.
    static let fallback = [ShareIceServer(urls: ["stun:stun.cloudflare.com:3478"], username: nil, credential: nil)]

    static func servers() async -> [ShareIceServer] {
        guard let url = ShareService.ice else { return fallback }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            let answer = try JSONDecoder().decode(Answer.self, from: data)
            return answer.iceServers.isEmpty ? fallback : answer.iceServers
        } catch {
            Log.sharing.error("Could not read the ice servers: \(error.localizedDescription)")
            return fallback
        }
    }
}

/// The websocket to the room, and the handful of messages that pass through
/// it. Everything here is about how to reach a Mac; the notes themselves
/// never come near it.
@MainActor
final class ShareSignal {
    enum Message: Sendable {
        /// How many are in the room, counting this Mac.
        case room(peers: Int)
        /// The other Mac has arrived.
        case peer
        /// The other Mac has left.
        case gone
        case sdp(kind: String, sdp: String)
        case ice(sdp: String, mid: String?, index: Int32)
    }

    var onMessage: ((Message) -> Void)?
    var onClose: ((String?) -> Void)?

    private let room: String
    private var task: URLSessionWebSocketTask?
    private var closed = false

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

    func send(sdp kind: String, _ sdp: String) {
        send(Wire(t: "sdp", kind: kind, sdp: sdp))
    }

    func send(candidate sdp: String, mid: String?, index: Int32) {
        send(Wire(t: "ice", candidate: sdp, mid: mid, index: index))
    }

    func close(_ reason: String? = nil) {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onClose?(reason)
    }

    // MARK: What goes over the wire

    private struct Wire: Codable {
        var t: String
        var peers: Int?
        var kind: String?
        var sdp: String?
        var candidate: String?
        var mid: String?
        var index: Int32?
    }

    private func send(_ wire: Wire) {
        guard !closed, let data = try? JSONEncoder().encode(wire),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            guard let error else { return }
            Log.sharing.error("Could not send a signal: \(error.localizedDescription)")
        }
    }

    private func read() {
        task?.receive { [weak self] result in
            // Only the text is carried across; the message itself stays here.
            var text: String?
            var failure: String?
            switch result {
            case .success(.string(let string)):
                text = string
            case .success(.data(let data)):
                text = String(data: data, encoding: .utf8)
            case .success:
                break
            case .failure(let error):
                failure = error.localizedDescription
            }
            let (payload, reason) = (text, failure)
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let reason { self.close(reason); return }
                if let payload { self.took(payload) }
                self.read()
            }
        }
    }

    private func took(_ text: String) {
        guard let data = text.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return }
        switch wire.t {
        case "room":
            onMessage?(.room(peers: wire.peers ?? 1))
        case "peer":
            onMessage?(.peer)
        case "gone":
            onMessage?(.gone)
        case "sdp":
            guard let kind = wire.kind, let sdp = wire.sdp else { return }
            onMessage?(.sdp(kind: kind, sdp: sdp))
        case "ice":
            guard let candidate = wire.candidate else { return }
            onMessage?(.ice(sdp: candidate, mid: wire.mid, index: wire.index ?? 0))
        default:
            break
        }
    }
}
