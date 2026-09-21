import CryptoKit
import Foundation
import Observation

/// Notes on their way out, and how far they have got.
///
/// This end makes the pairing code and waits in its room. The other end joins
/// by typing that code, and the two connect to each other directly.
@MainActor
@Observable
final class OutgoingShare {
    enum Stage: Equatable {
        /// The code is on screen and nobody has joined yet.
        case showing
        /// Connected. These are the four digits to read out, and the other
        /// end is deciding.
        case confirming(digits: String)
        case sent
        case declined
        case failed(String)
    }

    /// The code the other person types in.
    let pairing = ShareCode.make()
    private(set) var stage: Stage = .showing

    private let notes: [SharedNote]
    private let ours = Curve25519.KeyAgreement.PrivateKey()
    private var link: ShareLink?
    private var agreement: ShareHandshake.Agreement?
    private var deadline: Task<Void, Never>?

    init(notes: [SharedNote]) {
        self.notes = notes
    }

    func start() {
        let link = ShareLink(code: pairing, role: .shows)
        self.link = link
        // This end speaks first, so the other has something to answer.
        link.onOpen = { [weak self] in
            guard let self else { return }
            self.link?.send(ShareFrame(kind: .hello, key: self.ours.publicKey.rawRepresentation, name: Sharing.thisMac))
        }
        link.onFrame = { [weak self] in self?.took($0) }
        link.onClose = { [weak self] reason in self?.ended(reason) }
        link.start()
        // `give(up:)` leaves a share that already finished alone, so the timer
        // only bites when nobody ever came. It matches the room's own life in
        // worker.js: past that there is nothing left to join.
        deadline = Sharing.after(Sharing.timeout) { [weak self] in self?.give(up: "nobody used that code") }
    }

    func cancel() {
        deadline?.cancel()
        // Hanging up on purpose is not a failure to show.
        link?.onClose = nil
        link?.close()
    }

    private func took(_ frame: ShareFrame) {
        switch frame.kind {
        case .hello:
            guard case .showing = stage else { return }
            guard let key = frame.key,
                  let agreed = try? ShareHandshake.agree(ours: ours, theirs: key, pairing: pairing) else {
                give(up: "could not agree a key with that mac")
                return
            }
            agreement = agreed
            stage = .confirming(digits: agreed.code)
            link?.send(ShareFrame(kind: .offer, count: notes.count))
        case .decision:
            guard frame.accepted == true else {
                deadline?.cancel()
                stage = .declined
                link?.close()
                return
            }
            guard let agreement, let sealed = try? ShareHandshake.seal(SharePayload(notes: notes), with: agreement.key) else {
                give(up: "could not seal the notes")
                return
            }
            link?.send(ShareFrame(kind: .notes, sealed: sealed)) { [weak self] in
                guard let self, case .confirming = self.stage else { return }
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
        link?.close()
    }

    private func ended(_ reason: String?) {
        deadline?.cancel()
        guard !isFinished else { return }
        stage = .failed(reason ?? "that mac hung up")
    }

    private var isFinished: Bool {
        switch stage {
        case .sent, .declined, .failed: true
        case .showing, .confirming: false
        }
    }
}

/// Notes on their way in. Started by typing the code the other person read out.
@MainActor
@Observable
final class IncomingShare {
    enum Stage: Equatable {
        case joining
        /// The other end has offered. These are the four digits, which must
        /// match the ones on the sending Mac before this is worth a yes.
        case asking(from: String, digits: String, count: Int)
        case opening
        case arrived([SharedNote])
        case failed(String)
    }

    private(set) var stage: Stage = .joining

    private let pairing: String
    private let ours = Curve25519.KeyAgreement.PrivateKey()
    private var link: ShareLink?
    private var agreement: ShareHandshake.Agreement?
    private var theirName = "another mac"
    private var deadline: Task<Void, Never>?

    init(pairing: String) {
        self.pairing = pairing
    }

    func start() {
        let link = ShareLink(code: pairing, role: .types)
        self.link = link
        link.onFrame = { [weak self] in self?.took($0) }
        link.onClose = { [weak self] reason in self?.ended(reason) }
        link.start()
        deadline = Sharing.after(Sharing.timeout) { [weak self] in self?.give(up: "nothing came of that code") }
    }

    func accept() {
        guard case .asking = stage else { return }
        stage = .opening
        link?.send(ShareFrame(kind: .decision, accepted: true))
    }

    func decline() {
        deadline?.cancel()
        link?.send(ShareFrame(kind: .decision, accepted: false)) { [weak self] in self?.link?.close() }
    }

    /// The user is done reading, or has said no.
    func dismiss() {
        deadline?.cancel()
        link?.onClose = nil
        link?.close()
    }

    private func took(_ frame: ShareFrame) {
        switch frame.kind {
        case .hello:
            guard case .joining = stage, let key = frame.key,
                  let agreed = try? ShareHandshake.agree(ours: ours, theirs: key, pairing: pairing) else {
                give(up: "could not agree a key with that mac")
                return
            }
            agreement = agreed
            theirName = IncomingShare.clean(frame.name)
            link?.send(ShareFrame(kind: .hello, key: ours.publicKey.rawRepresentation, name: Sharing.thisMac))
        case .offer:
            guard let agreement, case .joining = stage else { return }
            stage = .asking(from: theirName, digits: agreement.code, count: max(0, frame.count ?? 0))
        case .notes:
            guard case .opening = stage, let agreement, let sealed = frame.sealed,
                  let payload = try? ShareHandshake.open(sealed, with: agreement.key) else {
                give(up: "the notes did not open")
                return
            }
            deadline?.cancel()
            stage = .arrived(payload.notes)
            link?.close()
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
        link?.close()
    }

    private func ended(_ reason: String?) {
        deadline?.cancel()
        guard !isFinished else { return }
        stage = .failed(reason ?? "that mac hung up")
    }

    private var isFinished: Bool {
        switch stage {
        case .arrived, .failed: true
        case .joining, .asking, .opening: false
        }
    }
}

/// The share this Mac is in, if any.
///
/// There is nothing running in the background here. Nothing is advertised,
/// nothing is listened for, and typeme.it hears from this Mac only while a
/// share the user started is being set up — and only enough to put the two
/// Macs in touch. One share at a time in each direction, because the code on
/// screen and the digits to check only mean anything if there is exactly one
/// of each.
@MainActor
@Observable
final class Sharing {
    static let shared = Sharing()

    /// As long as a room lives in worker.js. Past that there is nothing left
    /// to join, so waiting longer would only be waiting.
    static let timeout: Duration = .seconds(600)

    var outgoing: OutgoingShare?
    var incoming: IncomingShare?

    private init() {}

    /// What the other end calls this Mac.
    static var thisMac: String {
        Settings.shared.shareName
    }

    static func defaultName() -> String {
        IncomingShare.clean(Sharing.withoutLocal(ProcessInfo.processInfo.hostName))
    }

    /// Host names come with `.local` on the end, which is mDNS's business and
    /// not a thing to show a person.
    nonisolated static func withoutLocal(_ host: String) -> String {
        host.hasSuffix(".local") ? String(host.dropLast(6)) : host
    }

    /// Makes a code and waits in its room.
    func offer(_ notes: [SharedNote]) {
        outgoing?.cancel()
        let share = OutgoingShare(notes: notes)
        outgoing = share
        share.start()
    }

    /// Joins the room a code names. False when what was typed is not a code.
    @discardableResult
    func receive(_ typed: String) -> Bool {
        guard let pairing = ShareCode.tidy(typed) else { return false }
        incoming?.dismiss()
        let share = IncomingShare(pairing: pairing)
        incoming = share
        share.start()
        return true
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
