import Foundation

/// A framed conversation with the other Mac.
///
/// It puts the two ends in touch through the room named by the pairing code,
/// hands them to WebRTC to find a path between themselves, and from then on
/// carries `ShareFrame`s over the data channel. The frames and the sealing
/// are the same ones the app has always used: what changed underneath them is
/// only how the bytes travel.
@MainActor
final class ShareLink {
    enum Role {
        /// Showed the code, and waits in the room to be joined.
        case shows
        /// Was given the code, so it joins and makes the WebRTC offer.
        case types
    }

    /// The data channel is up and frames can go.
    var onOpen: (() -> Void)?
    var onFrame: ((ShareFrame) -> Void)?
    /// Over, with a reason worth showing or nil when the other end simply left.
    var onClose: ((String?) -> Void)?

    private let code: String
    private let role: Role
    private var signal: ShareSignal?
    private var peer: SharePeerConnection?
    private var buffer = Data()
    private var closed = false
    private var offered = false
    private var open = false

    init(code: String, role: Role) {
        self.code = code
        self.role = role
    }

    func start() {
        Task { @MainActor [weak self] in
            let servers = await ShareIce.servers()
            guard let self, !self.closed else { return }
            self.connect(servers)
        }
    }

    /// `then` runs once the frame is on the channel. SCTP delivers in order
    /// and does not drop, so a frame handed over is a frame that arrives —
    /// provided the channel is not closed underneath it, which is why the
    /// end that sends the notes waits to be hung up on rather than hanging up.
    func send(_ frame: ShareFrame, then: (() -> Void)? = nil) {
        guard !closed, open, let data = try? ShareWire.encode(frame) else { return }
        peer?.send(data)
        then?()
    }

    func close(_ reason: String? = nil) {
        guard !closed else { return }
        closed = true
        letGoOfTheServer()
        peer?.close()
        peer = nil
        onClose?(reason)
    }

    private func connect(_ servers: [ShareIceServer]) {
        let peer = SharePeerConnection(
            role: role == .types ? .offerer : .answerer,
            servers: servers,
            handlers: SharePeerHandlers(
                candidate: { [weak self] sdp, mid, index in
                    self?.signal?.send(candidate: sdp, mid: mid, index: index)
                },
                description: { [weak self] kind, sdp in
                    self?.signal?.send(sdp: kind, sdp)
                },
                open: { [weak self] in self?.opened() },
                data: { [weak self] data in self?.took(data) },
                closed: { [weak self] reason in self?.close(reason) }
            )
        )
        self.peer = peer

        let signal = ShareSignal(room: ShareCode.room(for: code))
        signal.onMessage = { [weak self] in self?.heard($0) }
        signal.onClose = { [weak self] reason in
            // Losing the room after the two Macs found each other is nothing:
            // the notes do not go through it. Before that, it is the share.
            guard let self, !self.open else { return }
            self.close(reason)
        }
        self.signal = signal
        signal.start()
    }

    private func heard(_ message: ShareSignal.Message) {
        switch message {
        case .room(let peers):
            if peers >= 2 { makeOffer() }
        case .peer:
            makeOffer()
        case .gone:
            if !open { close("the other mac left") }
        case .sdp(let kind, let sdp):
            peer?.took(remoteKind: kind, sdp: sdp)
        case .ice(let sdp, let mid, let index):
            peer?.took(remoteCandidate: sdp, mid: mid, index: index)
        }
    }

    /// Only the end that was given the code offers, and only once however
    /// many times the room says somebody is there.
    private func makeOffer() {
        guard role == .types, !offered, !closed else { return }
        offered = true
        peer?.start()
    }

    private func opened() {
        guard !open, !closed else { return }
        open = true
        // The two Macs are talking to each other now, so the room has done
        // its work and there is no reason to stay in it.
        letGoOfTheServer()
        onOpen?()
    }

    private func letGoOfTheServer() {
        guard let signal else { return }
        signal.onClose = nil
        signal.onMessage = nil
        signal.close()
        self.signal = nil
    }

    private func took(_ data: Data) {
        buffer.append(data)
        while !closed {
            do {
                guard let frame = try ShareWire.decode(from: &buffer) else { return }
                onFrame?(frame)
            } catch {
                Log.sharing.error("Bad frame: \(String(describing: error))")
                close("that mac sent something we could not read")
                return
            }
        }
    }
}
