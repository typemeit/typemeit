import Foundation
import WebRTC

/// One of the addresses a Mac can be reached at, as the worker hands them over.
struct ShareIceServer: Codable, Sendable {
    var urls: [String]
    var username: String?
    var credential: String?
}

/// What a peer connection tells its owner. Handed over whole at init rather
/// than set afterwards, so the delegate calls — which arrive on WebRTC's
/// threads — never read a property somebody else is writing.
struct SharePeerHandlers: Sendable {
    /// A way this Mac can be reached, to be passed to the other end.
    var candidate: @MainActor @Sendable (_ sdp: String, _ mid: String?, _ index: Int32) -> Void
    /// The offer or answer this end made.
    var description: @MainActor @Sendable (_ kind: String, _ sdp: String) -> Void
    /// The data channel is open and notes can go.
    var open: @MainActor @Sendable () -> Void
    var data: @MainActor @Sendable (Data) -> Void
    /// The connection is over, with a reason worth showing or nil.
    var closed: @MainActor @Sendable (String?) -> Void
}

/// The connection between the two Macs.
///
/// ICE tries every path it can find and keeps the one that works: two Macs on
/// the same network end up talking over it directly, and two on opposite sides
/// of the world go out through their routers. Neither case sends a note
/// through a server — the only exception is a pair behind NATs strict enough
/// that no direct path exists, which fall back to the TURN relay, and that
/// relay carries sealed bytes it has no key for.
final class SharePeerConnection: NSObject, @unchecked Sendable {
    enum Role {
        /// Makes the offer. The Mac that was given the code.
        case offerer
        /// Answers it. The Mac that showed the code.
        case answerer
    }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private let role: Role
    private let handlers: SharePeerHandlers
    /// Set once and never replaced: a closed connection is closed, not nil,
    /// so no WebRTC thread can catch this mid-swap.
    private let peer: RTCPeerConnection?

    /// `channel` is made here for the offerer and arrives on a WebRTC thread
    /// for the answerer, `waiting` is filled from whichever thread a candidate
    /// turns up on, and `finished` is read from both. The lock is over those
    /// three and nothing else.
    private let lock = NSLock()
    private var channel: RTCDataChannel?
    /// Candidates that arrived before there was a remote description to hang
    /// them on. Adding one early is an error, so they wait here.
    private var waiting: [RTCIceCandidate] = []
    private var finished = false

    init(role: Role, servers: [ShareIceServer], handlers: SharePeerHandlers) {
        self.role = role
        self.handlers = handlers
        super.init()

        let config = RTCConfiguration()
        config.iceServers = servers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peer = SharePeerConnection.factory.peerConnection(with: config, constraints: constraints, delegate: nil)
        peer?.delegate = self
    }

    /// The offerer opens the channel and makes the offer; the answerer waits
    /// to be given both.
    @MainActor
    func start() {
        guard role == .offerer, let peer else { return }
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        let channel = peer.dataChannel(forLabel: "notes", configuration: config)
        channel?.delegate = self
        lock.withLock { self.channel = channel }
        peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            self.take(local: sdp)
        }
    }

    @MainActor
    func took(remoteKind kind: String, sdp: String) {
        guard let peer else { return }
        let type: RTCSdpType = kind == "offer" ? .offer : .answer
        peer.setRemoteDescription(RTCSessionDescription(type: type, sdp: sdp)) { [weak self] _ in
            guard let self else { return }
            self.drainWaiting()
            guard type == .offer else { return }
            peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] answer, _ in
                guard let self, let answer else { return }
                self.take(local: answer)
            }
        }
    }

    @MainActor
    func took(remoteCandidate sdp: String, mid: String?, index: Int32) {
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
        guard let peer, peer.remoteDescription != nil else {
            lock.withLock { waiting.append(candidate) }
            return
        }
        peer.add(candidate) { _ in }
    }

    @MainActor
    func send(_ data: Data) {
        let channel = lock.withLock { self.channel }
        guard let channel, channel.readyState == .open else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    @MainActor
    func close() {
        lock.withLock {
            finished = true
            channel?.close()
            channel = nil
            waiting = []
        }
        peer?.close()
    }

    /// Sets a description this end made and hands it up to be sent on. What
    /// the handler needs is read out first: the description itself is not
    /// Sendable and has no business crossing to the main actor.
    private func take(local sdp: RTCSessionDescription) {
        let kind = sdp.type == .offer ? "offer" : "answer"
        let text = sdp.sdp
        let handlers = self.handlers
        peer?.setLocalDescription(sdp) { _ in
            Task { @MainActor in handlers.description(kind, text) }
        }
    }

    private func drainWaiting() {
        let held = lock.withLock { () -> [RTCIceCandidate] in
            let out = waiting
            waiting = []
            return out
        }
        for candidate in held { peer?.add(candidate) { _ in } }
    }

    private func give(up reason: String?) {
        let first = lock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard first else { return }
        let handlers = self.handlers
        Task { @MainActor in handlers.closed(reason) }
    }
}

// MARK: - What WebRTC calls back
//
// Every one of these arrives on a WebRTC thread. They do nothing but pull out
// the Sendable parts of what they were given and hand them to the main actor.

extension SharePeerConnection: RTCPeerConnectionDelegate {
    func peerConnection(_ connection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let (sdp, mid, index) = (candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex)
        let handlers = self.handlers
        Task { @MainActor in handlers.candidate(sdp, mid, index) }
    }

    func peerConnection(_ connection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
        lock.withLock { channel = dataChannel }
    }

    func peerConnection(_ connection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        switch state {
        case .failed:
            give(up: "could not find a way through to that mac")
        case .closed, .disconnected:
            give(up: nil)
        default:
            break
        }
    }

    func peerConnection(_ connection: RTCPeerConnection, didChange state: RTCSignalingState) {}
    func peerConnection(_ connection: RTCPeerConnection, didChange state: RTCIceConnectionState) {}
    func peerConnection(_ connection: RTCPeerConnection, didChange state: RTCIceGatheringState) {}
    func peerConnection(_ connection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ connection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ connection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnectionShouldNegotiate(_ connection: RTCPeerConnection) {}
}

extension SharePeerConnection: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let handlers = self.handlers
        switch dataChannel.readyState {
        case .open:
            Task { @MainActor in handlers.open() }
        case .closed:
            give(up: nil)
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        let handlers = self.handlers
        Task { @MainActor in handlers.data(data) }
    }
}
