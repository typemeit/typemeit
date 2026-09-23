import Foundation

/// The meeting state machine: pure, fed by the coordinator with what the
/// watch sees, the clock, and the user's clicks, answering with effects the
/// coordinator applies (docs/meetings.md 7.4). Nothing here touches audio,
/// the screen or the clock; every timer is a comparison against the `now`
/// the caller passes in.
struct MeetingMachine: Equatable {
    typealias Owner = ProcessOwner.Owner
    typealias Holder = MeetingWatch.Holder
    typealias Instant = ContinuousClock.Instant

    enum State: Equatable {
        case idle
        /// An owner's input turned on; `bothSince` is set while its output is
        /// on too, and the prompt comes after `confirm` of that.
        case candidate(owner: Owner, since: Instant, bothSince: Instant?)
        /// Asking. The pill and the menu item are both up.
        case prompting(owner: Owner, since: Instant)
        /// Not this call.
        case declined(owner: Owner)
        /// Owner nil for the room.
        case recording(owner: Owner?, since: Instant)
        /// The app released the mic; waiting for a rejoin. `since` is when
        /// it dropped.
        case paused(owner: Owner, since: Instant, before: Before)
        /// `stopRecording` was issued; waiting for `recorderEnded`.
        case finishing(owner: Owner?)
    }

    enum Before: Equatable { case prompting, declined, recording }

    enum Event: Equatable {
        case holders([Holder])
        case tick(Instant)
        /// The user, with the owner the pill or the menu named.
        case record(Owner)
        case decline, stop, room
        /// From the coordinator's silence deadline (docs/meetings.md 7.6).
        case bothSilent
        /// `didWake` also serves a device-configuration change: the next
        /// `holders` only seeds the input set.
        case willSleep, didWake
        case recorderEnded(recordedMs: Int)
    }

    enum Effect: Equatable {
        /// Capture into memory from the moment an owner is a candidate, so
        /// a recording keeps the minute before the user said yes (D20);
        /// `startRecording` for the same owner promotes it.
        case beginPreRoll(Owner), discardPreRoll
        case showPrompt(Owner), hidePrompt, showResumed(Owner)
        case startRecording(Owner?), pauseRecording, resumeRecording, stopRecording
        case finished(keep: Bool)
    }

    struct Rules: Equatable {
        var confirm: Duration
        var armTimeout: Duration
        var resume: Duration
        var rejoin: Duration
        var minimum: Duration
        var sessionCap: Duration
        var neverAsk: Set<String>

        static var fixed: Rules {
            Rules(confirm: .seconds(Fixed.meetingConfirmSeconds), armTimeout: .seconds(Fixed.meetingArmTimeoutSeconds),
                  resume: .seconds(Fixed.meetingResumeSeconds), rejoin: .seconds(Fixed.meetingRejoinSeconds),
                  minimum: .seconds(Fixed.meetingMinimumSeconds), sessionCap: .seconds(Fixed.meetingSessionCapSeconds),
                  neverAsk: [])
        }
    }

    private(set) var state: State = .idle
    /// Owners that held input at the last `holders` event. A candidate needs
    /// an edge, an owner whose input went from off to on, so an app already
    /// holding the mic at launch never prompts.
    private var inputHolders: Set<Owner> = []
    /// The next `holders` only seeds `inputHolders`: at start, after waking,
    /// and after a device-configuration change.
    private var seeding = true
    /// Owners whose candidacy timed out with no output: not re-armed until
    /// their input drops.
    private var armedOut: Set<Owner> = []
    /// When the current recording started, kept across a pause so the
    /// session cap measures the whole call.
    private var recordingSince: Instant?

    init() {}

    mutating func handle(_ event: Event, now: Instant, rules: Rules) -> [Effect] {
        switch event {
        case .holders(let holders): return handle(holders: holders, now: now, rules: rules)
        case .tick(let at): return tick(at, rules: rules)
        case .record(let owner): return record(owner, now: now)
        case .decline: return decline()
        case .stop: return stop()
        case .room: return room(now: now)
        case .bothSilent: return stop()
        case .willSleep: return willSleep()
        case .didWake: seeding = true; return []
        case .recorderEnded(let ms): return recorderEnded(ms, rules: rules)
        }
    }

    // MARK: Holders

    private mutating func handle(holders: [Holder], now: Instant, rules: Rules) -> [Effect] {
        let inputs = Set(holders.filter(\.input).map(\.owner))
        let outputs = Set(holders.filter(\.output).map(\.owner))
        let turnedOn = seeding ? [] : inputs.subtracting(inputHolders)
        inputHolders = inputs
        seeding = false
        armedOut = armedOut.intersection(inputs)
        let eligible = turnedOn.filter { !rules.neverAsk.contains($0.bundleID) && !armedOut.contains($0) }
        // Several at once: the one with both flags, else the first by bundle id.
        let newest = eligible.sorted { a, b in
            let (ao, bo) = (outputs.contains(a), outputs.contains(b))
            return ao != bo ? ao : a.bundleID < b.bundleID
        }.first

        switch state {
        case .idle:
            guard let newest else { return [] }
            state = .candidate(owner: newest, since: now, bothSince: outputs.contains(newest) ? now : nil)
            return [.beginPreRoll(newest)]
        case .candidate(let owner, let since, let bothSince):
            guard inputs.contains(owner) else { state = .idle; return [.discardPreRoll] }
            // A later arrival with both flags outranks a candidate still waiting for output.
            if let newest, newest != owner, outputs.contains(newest), bothSince == nil {
                state = .candidate(owner: newest, since: now, bothSince: now)
                return [.discardPreRoll, .beginPreRoll(newest)]
            }
            let both: Instant? = outputs.contains(owner) ? (bothSince ?? now) : nil
            state = .candidate(owner: owner, since: since, bothSince: both)
            return []
        case .prompting(let owner, _):
            if !inputs.contains(owner) {
                state = .paused(owner: owner, since: now, before: .prompting)
                return [.hidePrompt, .discardPreRoll]
            }
            if let newest, newest != owner {
                state = .candidate(owner: newest, since: now, bothSince: outputs.contains(newest) ? now : nil)
                return [.hidePrompt, .discardPreRoll, .beginPreRoll(newest)]
            }
            return []
        case .declined(let owner):
            if !inputs.contains(owner) { state = .paused(owner: owner, since: now, before: .declined) }
            return []
        case .recording(let owner?, _):
            if !inputs.contains(owner) {
                state = .paused(owner: owner, since: now, before: .recording)
                return [.pauseRecording]
            }
            return []
        case .recording(nil, _):
            return []
        case .paused(let owner, _, let before):
            guard inputs.contains(owner) else { return [] }
            switch before {
            case .recording:
                state = .recording(owner: owner, since: recordingSince ?? now)
                return [.resumeRecording, .showResumed(owner)]
            case .prompting:
                state = .prompting(owner: owner, since: now)
                return [.showPrompt(owner)]
            case .declined:
                state = .declined(owner: owner)
                return []
            }
        case .finishing:
            return []
        }
    }

    // MARK: Time

    private mutating func tick(_ now: Instant, rules: Rules) -> [Effect] {
        switch state {
        case .candidate(let owner, let since, let bothSince):
            if let bothSince, now - bothSince >= rules.confirm {
                state = .prompting(owner: owner, since: now)
                return [.showPrompt(owner)]
            }
            if bothSince == nil, now - since >= rules.armTimeout {
                armedOut.insert(owner)
                state = .idle
                return [.discardPreRoll]
            }
            return []
        case .recording(let owner, let since):
            guard now - since >= rules.sessionCap else { return [] }
            state = .finishing(owner: owner)
            return [.stopRecording]
        case .paused(let owner, let since, let before):
            switch before {
            case .recording:
                guard now - since >= rules.resume else { return [] }
                state = .finishing(owner: owner)
                return [.stopRecording]
            case .prompting, .declined:
                if now - since >= rules.rejoin { state = .idle }
                return []
            }
        case .idle, .prompting, .declined, .finishing:
            return []
        }
    }

    // MARK: The user

    private mutating func record(_ owner: Owner, now: Instant) -> [Effect] {
        switch state {
        case .idle, .candidate, .declined:
            return start(owner, now: now)
        case .prompting(let prompting, _):
            guard prompting == owner else { return [] }
            return [.hidePrompt] + start(owner, now: now)
        case .paused(_, _, let before) where before != .recording:
            return start(owner, now: now)
        case .paused, .recording, .finishing:
            return []
        }
    }

    private mutating func start(_ owner: Owner?, now: Instant) -> [Effect] {
        recordingSince = now
        state = .recording(owner: owner, since: now)
        return [.startRecording(owner)]
    }

    private mutating func decline() -> [Effect] {
        guard case .prompting(let owner, _) = state else { return [] }
        state = .declined(owner: owner)
        return [.hidePrompt, .discardPreRoll]
    }

    private mutating func stop() -> [Effect] {
        switch state {
        case .recording(let owner, _):
            state = .finishing(owner: owner)
            return [.stopRecording]
        case .paused(let owner, _, .recording):
            state = .finishing(owner: owner)
            return [.stopRecording]
        default:
            return []
        }
    }

    /// The room is started by hand only, and only while no meeting is
    /// recording; a call being asked about gives way to it.
    private mutating func room(now: Instant) -> [Effect] {
        switch state {
        case .idle, .declined:
            return start(nil, now: now)
        case .candidate:
            return [.discardPreRoll] + start(nil, now: now)
        case .prompting:
            return [.hidePrompt, .discardPreRoll] + start(nil, now: now)
        case .recording, .paused, .finishing:
            return []
        }
    }

    private mutating func willSleep() -> [Effect] {
        switch state {
        case .idle, .finishing:
            return []
        case .recording(let owner, _):
            state = .finishing(owner: owner)
            return [.stopRecording]
        case .paused(let owner, _, .recording):
            state = .finishing(owner: owner)
            return [.stopRecording]
        case .prompting:
            state = .idle
            return [.hidePrompt, .discardPreRoll]
        case .candidate:
            state = .idle
            return [.discardPreRoll]
        case .declined, .paused:
            state = .idle
            return []
        }
    }

    private mutating func recorderEnded(_ recordedMs: Int, rules: Rules) -> [Effect] {
        guard case .finishing(let owner) = state else { return [] }
        state = .idle
        recordingSince = nil
        let keep = owner == nil || Duration.milliseconds(recordedMs) >= rules.minimum
        return [.finished(keep: keep)]
    }
}
