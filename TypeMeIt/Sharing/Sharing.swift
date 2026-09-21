import Foundation
import Observation

/// Notes sealed and left for someone to collect.
@MainActor
@Observable
final class OutgoingShare {
    enum Stage: Equatable {
        case sealing
        /// Left, and waiting to be collected. This is the code to hand over.
        case ready(code: String)
        case failed(String)
    }

    private(set) var stage: Stage = .sealing

    private let notes: [SharedNote]
    private var work: Task<Void, Never>?

    init(notes: [SharedNote]) {
        self.notes = notes
    }

    func start() {
        let pickup = ShareCode.make()
        let payload = SharePayload(from: Sharing.thisMac, notes: notes)
        work = Task { [weak self] in
            do {
                // Six hundred thousand rounds of PBKDF2 is a third of a
                // second, which is a third of a second the window should
                // not spend frozen.
                let blob = try await Task.detached { try ShareSeal.seal(payload, secret: pickup.secret) }.value
                try await ShareDrop.put(blob, name: pickup.name)
                guard let self, !Task.isCancelled else { return }
                self.stage = .ready(code: pickup.code)
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.sharing.error("Could not leave the notes: \(String(describing: error))")
                self.stage = .failed(Sharing.reason(error))
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
    }
}

/// Notes collected with a code somebody handed over.
@MainActor
@Observable
final class IncomingShare {
    enum Stage: Equatable {
        case fetching
        case arrived(from: String, notes: [SharedNote])
        case failed(String)
    }

    private(set) var stage: Stage = .fetching

    private let pickup: ShareCode.Pickup
    private var work: Task<Void, Never>?

    init(pickup: ShareCode.Pickup) {
        self.pickup = pickup
    }

    func start() {
        let pickup = self.pickup
        work = Task { [weak self] in
            do {
                let blob = try await ShareDrop.take(name: pickup.name)
                let payload = try await Task.detached { try ShareSeal.open(blob, secret: pickup.secret) }.value
                guard let self, !Task.isCancelled else { return }
                self.stage = .arrived(from: Sharing.clean(payload.from), notes: payload.notes)
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.sharing.error("Could not collect the notes: \(String(describing: error))")
                self.stage = .failed(Sharing.reason(error))
            }
        }
    }

    func dismiss() {
        work?.cancel()
        work = nil
    }
}

/// The share this Mac is in, if any.
///
/// Nothing runs in the background. Nothing is advertised and nothing is
/// listened for; typeme.it hears from this Mac twice in a share — once to
/// leave the sealed bytes and once to collect them — and holds no key for
/// what it was handed. One share at a time in each direction, because the
/// code on screen only means anything if there is one of it.
@MainActor
@Observable
final class Sharing {
    static let shared = Sharing()

    var outgoing: OutgoingShare?
    var incoming: IncomingShare?

    private init() {}

    /// What the other end sees this Mac called, from inside the seal.
    static var thisMac: String {
        Settings.shared.shareName
    }

    static func defaultName() -> String {
        clean(withoutLocal(ProcessInfo.processInfo.hostName))
    }

    /// Host names come with `.local` on the end, which is mDNS's business
    /// and not a thing to show a person.
    nonisolated static func withoutLocal(_ host: String) -> String {
        host.hasSuffix(".local") ? String(host.dropLast(6)) : host
    }

    /// A name that came out of a drop is shown to the user, so it is cut to
    /// a length that cannot push a window's buttons off the edge and
    /// stripped of the line breaks that would let it fake one.
    nonisolated static func clean(_ name: String?) -> String {
        let one = (name ?? "").components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = one.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "another mac" }
        return trimmed.count <= 40 ? trimmed : String(trimmed.prefix(40)) + "…"
    }

    /// Seals the notes and leaves them.
    func offer(_ notes: [SharedNote]) {
        outgoing?.cancel()
        let share = OutgoingShare(notes: notes)
        outgoing = share
        share.start()
    }

    /// Collects what a code names. False when what was typed is not a code.
    @discardableResult
    func receive(_ typed: String) -> Bool {
        guard let pickup = ShareCode.tidy(typed) else { return false }
        incoming?.dismiss()
        let share = IncomingShare(pickup: pickup)
        incoming = share
        share.start()
        return true
    }

    /// What went wrong, in the app's own words rather than the network's.
    nonisolated static func reason(_ error: Error) -> String {
        if let drop = error as? ShareDrop.Failure {
            return switch drop {
            case .tooMuch: "that is more than fits in one share"
            case .gone: "nothing there — that code is used up, or the ten minutes are over"
            case .unreachable(let what): "could not reach \(what)"
            }
        }
        if let seal = error as? ShareSeal.Failure {
            return switch seal {
            case .cannotSeal: "that is more than fits in one share"
            // Which of the two it was is not the user's problem, and saying
            // would be telling someone guessing that they were close.
            case .notOurs, .cannotOpen: "that code does not open it"
            }
        }
        return "that did not work"
    }
}
