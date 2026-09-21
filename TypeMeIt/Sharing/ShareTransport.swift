import Foundation

/// How a frame gets to the other Mac.
///
/// There is one of these today, `ShareRelay`, and the shape is here because
/// there is meant to be a second. The WebRTC transport on
/// `claude/share-webrtc-transport` connects the two Macs directly, keeping
/// the notes off typeme.it altogether, and it needs nothing from `ShareLink`
/// that is not already here. When it comes back it comes back as another
/// conformance and `ShareLink` does not change.
@MainActor
protocol ShareTransport: AnyObject {
    /// The other Mac is there and frames can go.
    var onOpen: (() -> Void)? { get set }
    /// One frame's worth of bytes, as the other Mac sent them.
    var onData: ((Data) -> Void)? { get set }
    /// Over, with a reason worth showing or nil when the other end simply left.
    var onClose: ((String?) -> Void)? { get set }

    func start()
    func send(_ data: Data)
    func close()
}
