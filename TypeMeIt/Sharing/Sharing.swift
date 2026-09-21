import CryptoKit
import Foundation
import Network
import Observation

/// Another Mac running type me it, seen on this network.
struct SharePeer: Identifiable, Equatable, Sendable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

/// Notes on their way out, and how far they have got.
@MainActor
@Observable
final class OutgoingShare {
    enum Stage: Equatable {
        /// Dialling, and waiting for the other end to say hello.
        case reaching
        /// Both ends agree. These are the digits to read out, and the
        /// receiver is being asked.
        case waiting(code: String)
        case sent
        case declined
        case failed(String)
    }

    let peer: SharePeer
    private(set) var stage: Stage = .reaching

    private let notes: [SharedNote]
    private let ours = Curve25519.KeyAgreement.PrivateKey()
    private var channel: ShareChannel?
    private var agreement: ShareHandshake.Agreement?
    private var deadline: Task<Void, Never>?

    init(notes: [SharedNote], to peer: SharePeer) {
        self.notes = notes
        self.peer = peer
    }

    func start() {
        let channel = ShareChannel(to: peer.endpoint)
        self.channel = channel
        // The channel holds this closure, so it is reached back through
        // `self` rather than captured: a strong `channel` here would be a
        // cycle that never lets the connection go.
        channel.onReady = { [weak self] in
            guard let self else { return }
            self.channel?.send(ShareFrame(kind: .hello, key: self.ours.publicKey.rawRepresentation, name: Sharing.thisMac))
        }
        channel.onFrame = { [weak self] in self?.took($0) }
        channel.onClose = { [weak self] reason in self?.ended(reason) }
        channel.start()
        // `give(up:)` leaves a share that already finished alone, so the
        // timer only bites when the other end never answered.
        deadline = Sharing.after(Sharing.timeout) { [weak self] in self?.give(up: "no answer") }
    }

    func cancel() {
        deadline?.cancel()
        // Hanging up on purpose is not a failure to show.
        channel?.onClose = nil
        channel?.close()
    }

    private func took(_ frame: ShareFrame) {
        switch frame.kind {
        case .hello:
            guard case .reaching = stage else { return }
            guard let key = frame.key, let agreed = try? ShareHandshake.agree(ours: ours, theirs: key) else {
                give(up: "could not agree a key with that Mac")
                return
            }
            agreement = agreed
            stage = .waiting(code: agreed.code)
            channel?.send(ShareFrame(kind: .offer, count: notes.count))
        case .decision:
            guard frame.accepted == true else {
                deadline?.cancel()
                stage = .declined
                channel?.close()
                return
            }
            guard let agreement, let sealed = try? ShareHandshake.seal(SharePayload(notes: notes), with: agreement.key) else {
                give(up: "could not seal the notes")
                return
            }
            // Sent means the notes are out, not merely queued: the sheet's
            // button turns to "close" on this, and a close cancels the
            // connection. The other end hangs up once it has them.
            channel?.send(ShareFrame(kind: .notes, sealed: sealed)) { [weak self] in
                guard let self, case .waiting = self.stage else { return }
                self.deadline?.cancel()
                self.stage = .sent
            }
        case .offer, .notes:
            // Nothing the sending end answers.
            break
        }
    }

    private func give(up reason: String) {
        deadline?.cancel()
        guard !isFinished else { return }
        stage = .failed(reason)
        channel?.close()
    }

    private func ended(_ reason: String?) {
        deadline?.cancel()
        guard !isFinished else { return }
        stage = .failed(reason ?? "that Mac hung up")
    }

    private var isFinished: Bool {
        switch stage {
        case .sent, .declined, .failed: true
        case .reaching, .waiting: false
        }
    }
}

/// Notes on their way in, and what the user has been asked.
@MainActor
@Observable
final class IncomingShare {
    enum Stage: Equatable {
        case greeting
        /// The other end has offered. These are the digits, which must match
        /// the ones on the sending Mac before this is worth a yes.
        case asking(from: String, code: String, count: Int)
        case opening
        case arrived([SharedNote])
        case failed(String)
    }

    private(set) var stage: Stage = .greeting

    private let ours = Curve25519.KeyAgreement.PrivateKey()
    private let channel: ShareChannel
    private var agreement: ShareHandshake.Agreement?
    private var theirName = "another mac"
    private var deadline: Task<Void, Never>?

    init(_ channel: ShareChannel) {
        self.channel = channel
    }

    func start() {
        channel.onFrame = { [weak self] in self?.took($0) }
        channel.onClose = { [weak self] reason in self?.ended(reason) }
        channel.start()
        deadline = Sharing.after(Sharing.timeout) { [weak self] in self?.give(up: "that Mac went quiet") }
    }

    func accept() {
        guard case .asking = stage else { return }
        stage = .opening
        channel.send(ShareFrame(kind: .decision, accepted: true))
    }

    func decline() {
        deadline?.cancel()
        channel.send(ShareFrame(kind: .decision, accepted: false)) { [weak self] in self?.channel.close() }
    }

    /// The user is done reading, or has said no.
    func dismiss() {
        deadline?.cancel()
        channel.onClose = nil
        channel.close()
    }

    private func took(_ frame: ShareFrame) {
        switch frame.kind {
        case .hello:
            guard case .greeting = stage, let key = frame.key,
                  let agreed = try? ShareHandshake.agree(ours: ours, theirs: key) else {
                give(up: "could not agree a key with that Mac")
                return
            }
            agreement = agreed
            theirName = IncomingShare.clean(frame.name)
            channel.send(ShareFrame(kind: .hello, key: ours.publicKey.rawRepresentation, name: Sharing.thisMac))
        case .offer:
            guard let agreement, case .greeting = stage else { return }
            stage = .asking(from: theirName, code: agreement.code, count: max(0, frame.count ?? 0))
        case .notes:
            guard case .opening = stage, let agreement, let sealed = frame.sealed,
                  let payload = try? ShareHandshake.open(sealed, with: agreement.key) else {
                give(up: "the notes did not open")
                return
            }
            deadline?.cancel()
            stage = .arrived(payload.notes)
            channel.close()
        case .decision:
            // Nothing the receiving end answers.
            break
        }
    }

    /// A name off the network is shown to the user, so it is cut to a length
    /// that cannot push a prompt's buttons off the edge and stripped of the
    /// line breaks that would let it fake one.
    nonisolated static func clean(_ name: String?) -> String {
        let one = (name ?? "").components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = one.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "another mac" }
        return trimmed.count <= 40 ? trimmed : String(trimmed.prefix(40)) + "…"
    }

    private func give(up reason: String) {
        deadline?.cancel()
        guard !isFinished else { return }
        stage = .failed(reason)
        channel.close()
    }

    private func ended(_ reason: String?) {
        deadline?.cancel()
        guard !isFinished else { return }
        stage = .failed(reason ?? "that Mac hung up")
    }

    private var isFinished: Bool {
        switch stage {
        case .arrived, .failed: true
        case .greeting, .asking, .opening: false
        }
    }
}

/// Finding the other Macs, and answering the ones that call.
///
/// Off unless the user turns it on: an app that advertises the computer's
/// name on every network it joins is not one that can say nothing leaves the
/// computer. While it is on, this Mac is listed by name on the local network
/// and will answer a connection, but nothing is read out or written down
/// until somebody here has been shown the digits and said yes.
@MainActor
@Observable
final class Sharing {
    static let shared = Sharing()

    static let serviceType = "_typemeit._tcp"
    /// How long either end waits on the other before giving up.
    static let timeout: Duration = .seconds(90)

    /// The Macs on this network, by name.
    private(set) var peers: [SharePeer] = []
    /// Whether the listener and browser are up.
    private(set) var on = false
    /// The share this Mac is sending, if any.
    var outgoing: OutgoingShare?
    /// The share this Mac is being offered, if any. One at a time: a second
    /// caller is hung up on rather than allowed to stack another prompt.
    var incoming: IncomingShare?

    private var listener: NWListener?
    private var browser: NWBrowser?

    private init() {}

    /// What this Mac calls itself on the network.
    static var thisMac: String {
        Settings.shared.shareName
    }

    static func defaultName() -> String {
        IncomingShare.clean(Sharing.withoutLocal(ProcessInfo.processInfo.hostName))
    }

    /// Bonjour hands back host names with `.local` on the end, which is
    /// mDNS's business and not a thing to show a person.
    nonisolated static func withoutLocal(_ host: String) -> String {
        host.hasSuffix(".local") ? String(host.dropLast(6)) : host
    }

    /// Matches `Settings.sharing`. Safe to call again.
    func sync() {
        if Settings.shared.sharing { start() } else { stop() }
    }

    func start() {
        guard !on else { return }
        on = true
        listen()
        browse()
    }

    func stop() {
        on = false
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        peers = []
        outgoing?.cancel()
        outgoing = nil
        incoming?.dismiss()
        incoming = nil
    }

    /// Puts the listener back up under the new name, and the browser with
    /// it: the browser filters this Mac out of its own results by name, so a
    /// stale one would list us to ourselves. A share already under way is
    /// left alone.
    func rename() {
        guard on else { return }
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        peers = []
        listen()
        browse()
    }

    func send(_ notes: [SharedNote], to peer: SharePeer) {
        outgoing?.cancel()
        let share = OutgoingShare(notes: notes, to: peer)
        outgoing = share
        share.start()
    }

    private func listen() {
        do {
            let listener = try NWListener(using: ShareChannel.parameters)
            listener.service = NWListener.Service(name: Sharing.thisMac, type: Sharing.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.answer(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Log.sharing.error("Listener failed: \(error.localizedDescription)")
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Log.sharing.error("Could not listen: \(error.localizedDescription)")
            on = false
        }
    }

    private func answer(_ connection: NWConnection) {
        // A prompt is already up, or notes are already on their way in.
        // Taking a second call would mean two prompts over each other, and
        // the user could not tell which they were answering.
        guard incoming == nil else { connection.cancel(); return }
        let share = IncomingShare(ShareChannel(connection))
        incoming = share
        share.start()
        NotificationCenter.default.post(name: Sharing.offered, object: nil)
    }

    /// Posted when a Mac calls, so the window that asks can be opened.
    nonisolated static let offered = Notification.Name("it.typeme.shareOffered")

    private func browse() {
        let browser = NWBrowser(for: .bonjour(type: Sharing.serviceType, domain: nil), using: ShareChannel.parameters)
        let ours = Sharing.thisMac
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Sharing.peers(from: results, excluding: ours)
            Task { @MainActor in self?.peers = found }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.sharing.error("Browser failed: \(error.localizedDescription)")
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// The browse results as peers, this Mac left out and the rest in name
    /// order so the list does not reshuffle as services come and go.
    nonisolated static func peers(from results: Set<NWBrowser.Result>, excluding ours: String) -> [SharePeer] {
        var out: [SharePeer] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            // Bonjour hands back the service this Mac is advertising too.
            guard name != ours else { continue }
            out.append(SharePeer(name: name, endpoint: result.endpoint))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A one-shot timer that runs on the main actor and cancels cleanly.
    static func after(_ duration: Duration, _ body: @escaping @MainActor @Sendable () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            body()
        }
    }
}
