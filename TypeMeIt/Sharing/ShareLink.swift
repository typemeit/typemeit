import Foundation

/// A framed conversation with the other Mac.
///
/// It puts the two ends in touch through the room named by the pairing code
/// and carries `ShareFrame`s between them. What it knows about the transport
/// is only what `ShareTransport` says, so the day the notes go directly
/// between the two Macs instead of through a room, this file does not change.
@MainActor
final class ShareLink {
    /// The other Mac is there and frames can go.
    var onOpen: (() -> Void)?
    var onFrame: ((ShareFrame) -> Void)?
    /// Over, with a reason worth showing or nil when the other end simply left.
    var onClose: ((String?) -> Void)?

    private let transport: ShareTransport
    private var buffer = Data()
    private var closed = false
    private var open = false

    init(code: String) {
        transport = ShareRelay(room: ShareCode.room(for: code))
    }

    func start() {
        transport.onOpen = { [weak self] in self?.opened() }
        transport.onData = { [weak self] in self?.took($0) }
        transport.onClose = { [weak self] reason in self?.close(reason) }
        transport.start()
    }

    /// `then` runs once the frame is on its way. The end that sends the notes
    /// waits to be hung up on rather than hanging up, so that a close of its
    /// own cannot overtake the last frame.
    func send(_ frame: ShareFrame, then: (() -> Void)? = nil) {
        guard !closed, open else { return }
        do {
            transport.send(try ShareWire.encode(frame))
            then?()
        } catch {
            Log.sharing.error("Could not encode a frame: \(String(describing: error))")
            close("that is more than can go in one share")
        }
    }

    func close(_ reason: String? = nil) {
        guard !closed else { return }
        closed = true
        transport.onClose = nil
        transport.close()
        onClose?(reason)
    }

    private func opened() {
        guard !open, !closed else { return }
        open = true
        onOpen?()
    }

    /// One websocket message is one frame, so the length in front of each is
    /// not doing much here. It stays because it is what lets the same link
    /// run over a transport that hands over a stream of bytes rather than
    /// messages, which is what a WebRTC data channel does.
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
