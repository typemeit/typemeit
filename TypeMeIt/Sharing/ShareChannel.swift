import Foundation
import Network

/// One connection between two Macs, framed.
///
/// Everything runs on the main queue. What crosses is a few kilobytes of
/// text, so there is nothing to gain from a queue of its own, and keeping
/// Network.framework's callbacks on the actor the UI already lives on takes
/// the concurrency out of a piece of code that is fiddly enough without it.
@MainActor
final class ShareChannel {
    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false

    /// A whole frame arrived.
    var onFrame: ((ShareFrame) -> Void)?
    /// The connection is ready to be written to.
    var onReady: (() -> Void)?
    /// The connection is over, with a reason worth showing or nil when the
    /// other end simply hung up.
    var onClose: ((String?) -> Void)?

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Dials a peer found by the browser.
    convenience init(to endpoint: NWEndpoint) {
        self.init(NWConnection(to: endpoint, using: ShareChannel.parameters))
    }

    /// TCP. Peers are found over Bonjour, which does not leave the local
    /// network, and cellular is ruled out so a share is never carried over a
    /// phone's data rather than the network both Macs are on.
    static var parameters: NWParameters {
        let p = NWParameters.tcp
        p.includePeerToPeer = true
        p.prohibitedInterfaceTypes = [.cellular]
        return p
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in
                    guard let self, !self.closed else { return }
                    self.onReady?()
                    self.read()
                }
            case .failed(let error):
                let reason = error.localizedDescription
                Task { @MainActor in self?.close(reason) }
            case .cancelled:
                Task { @MainActor in self?.close() }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    /// `then` runs once the bytes are out, so a caller that hangs up after a
    /// frame does not cut its own last write off.
    func send(_ frame: ShareFrame, then: (@MainActor @Sendable () -> Void)? = nil) {
        guard !closed, let data = try? ShareWire.encode(frame) else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            guard error == nil, let then else { return }
            Task { @MainActor in then() }
        })
    }

    /// Hangs up. The reason, when there is one, reaches `onClose` once.
    func close(_ reason: String? = nil) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(reason)
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let failure { self.close(failure); return }
                if let data, !data.isEmpty { self.took(data) }
                if complete { self.close(); return }
                if !self.closed { self.read() }
            }
        }
    }

    private func took(_ data: Data) {
        buffer.append(data)
        while !closed {
            do {
                guard let frame = try ShareWire.decode(from: &buffer) else { return }
                onFrame?(frame)
            } catch {
                Log.sharing.error("Bad frame: \(String(describing: error))")
                close("that Mac sent something we could not read")
                return
            }
        }
    }
}
