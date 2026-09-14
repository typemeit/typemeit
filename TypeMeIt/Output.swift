import AppKit
import CoreGraphics
import Foundation

/// Pastes through the clipboard with Cmd+V and puts back what was there once
/// the target app has read the transcript.
@MainActor
enum Output {
    /// The transaction whose clipboard write has not been put back yet.
    private static var pending: PasteTransaction?

    /// What the clipboard held before a paste.
    enum Saved {
        case text(String)
        case image(Data, NSPasteboard.PasteboardType)
        case nothing

        /// Text, or an image when there is no text.
        static func capture(from pb: NSPasteboard) -> Saved {
            if let text = pb.string(forType: .string), !text.isEmpty { return .text(text) }
            for type in [NSPasteboard.PasteboardType.tiff, .png] {
                if let data = pb.data(forType: type) { return .image(data, type) }
            }
            return .nothing
        }

        var description: String {
            switch self {
            case .text(let text): "text (\(text.count) chars)"
            case .image: "an image"
            case .nothing: "nothing"
            }
        }
    }

    /// Each modifier flag and the key that produces it, in the order they
    /// are pressed.
    private static let modifierKeys: [(flag: CGEventFlags, key: CGKeyCode)] = [
        (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55),
    ]

    /// Posts `keycode` down and up carrying `flags`, wrapped in down and up
    /// events for each modifier in `flags`. Virtual machines and apps that
    /// rebuild modifier state from the key stream type a bare "v" when the
    /// V event alone carries the Command flag. Returns false when an event
    /// could not be created (Accessibility missing); nothing is posted then.
    private static func post(keycode: CGKeyCode, flags: CGEventFlags) -> Bool {
        var sequence: [(key: CGKeyCode, down: Bool, flags: CGEventFlags)] = []
        var held: CGEventFlags = []
        for modifier in modifierKeys where flags.contains(modifier.flag) {
            held.insert(modifier.flag)
            sequence.append((modifier.key, true, held))
        }
        sequence.append((keycode, true, flags))
        sequence.append((keycode, false, flags))
        for modifier in modifierKeys.reversed() where flags.contains(modifier.flag) {
            held.remove(modifier.flag)
            sequence.append((modifier.key, false, held))
        }

        var events: [CGEvent] = []
        for step in sequence {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: step.key, keyDown: step.down) else { return false }
            event.flags = step.flags
            events.append(event)
        }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    private static func sleep(ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// A paste under way. `posted` is known at once; whether anything read
    /// the clipboard comes later.
    struct Paste {
        /// False when the key events could not be posted (Accessibility
        /// missing).
        let posted: Bool
        fileprivate let transaction: PasteTransaction

        /// `true` once something has read the clipboard, `false` when nothing
        /// has by `ms` after Cmd+V: the chord landed nowhere. A read before
        /// the chord counts as landed, since the target's own read cannot be
        /// seen after it.
        func landed(within ms: Int) async -> Bool {
            await transaction.read(within: ms)
        }
    }

    /// Promises the transcript on the clipboard, posts Cmd+V and returns.
    /// The clipboard is put back later, once the target has read it (see
    /// `PasteTransaction`).
    static func paste(_ text: String, autoSubmit: Bool, autoSubmitKey: AutoSubmitKey) async -> Paste {
        let pb = NSPasteboard.general
        pending?.abandon(on: pb)

        let saved = Saved.capture(from: pb)
        let transaction = PasteTransaction(text: text, saved: saved)
        transaction.publish(on: pb)
        pending = transaction
        await sleep(ms: Fixed.pasteDelayBeforeMs)

        let posted = post(keycode: 9, flags: .maskCommand)  // V
        transaction.chordPosted()
        if !posted { Log.output.error("Could not post Cmd+V; Accessibility may be missing") }
        DebugLog.write("Paste: Cmd+V \(posted ? "posted" : "not posted") to \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "no frontmost app") with \(text.count) chars \"\(DebugLog.excerpt(text))\" promised on the clipboard, which held \(saved.description); accessibility \(AXIsProcessTrusted() ? "granted" : "missing"); secure input \(SecureInput.owner.map { "held by \($0.name)" } ?? "off")")

        var submit: (@MainActor () -> Void)?
        if autoSubmit {
            let flags: CGEventFlags = switch autoSubmitKey {
            case .enter: []
            case .ctrlEnter: .maskControl
            case .cmdEnter: .maskCommand
            }
            submit = { _ = post(keycode: 36, flags: flags) }  // Return
        }
        Task { await transaction.settle(posted: posted, submit: submit, isCurrent: { pending === transaction }) }

        if posted, DebugLog.enabled {
            if autoSubmit {
                DebugLog.write("Paste check skipped: auto submit is on")
            } else {
                Task { await checkLanded(text, previousClipboard: saved) }
            }
        }
        return Paste(posted: posted, transaction: transaction)
    }

    /// Leaves `text` on the clipboard. A pending paste is dropped rather than
    /// put back: the user asked for the transcript.
    static func copyToClipboard(_ text: String) {
        pending = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    fileprivate static func describe(_ pb: NSPasteboard) -> String {
        Saved.capture(from: pb).description
    }

    // MARK: Debug logs

    /// Reads the focused field back a moment after the paste and logs whether
    /// the transcript is there, or the clipboard's previous text is instead:
    /// the sign of the target app taking Cmd+V after the clipboard was put
    /// back. Only the verdict is logged; the field's text is never written
    /// out. Skipped where the read-back is: password fields and the apps on
    /// its denylist.
    private static func checkLanded(_ text: String, previousClipboard: Saved) async {
        if let owner = SecureInput.owner {
            DebugLog.write("Paste check skipped: secure input held by \(owner.name)")
            return
        }
        try? await Task.sleep(for: ReadBackTiming.settle)
        guard let field = FocusedTextField.captureFrontmost() else {
            DebugLog.write("Paste check: no readable text field has focus")
            return
        }
        if let bundle = field.bundleId, ReadBack.denied(bundle) {
            DebugLog.write("Paste check skipped: \(bundle) is never read back")
            return
        }
        let previous: String? = if case .text(let text) = previousClipboard { text } else { nil }
        var lastCount: Int?
        var previousSeen = false
        for attempt in 0..<PasteCheck.reads {
            if attempt > 0 { try? await Task.sleep(for: PasteCheck.retry) }
            guard let value = field.value() else { continue }
            lastCount = value.count
            if ReadBackText.snapshot(value: value, pasted: text, caretUTF16: nil) != nil {
                DebugLog.write("Paste check: transcript found in the field on read \(attempt + 1)")
                return
            }
            if let previous, previous.count >= PasteCheck.minimumClipboardChars,
               ReadBackText.snapshot(value: value, pasted: previous, caretUTF16: nil) != nil {
                previousSeen = true
            }
        }
        guard let lastCount else {
            DebugLog.write("Paste check: the field's value could not be read")
            return
        }
        DebugLog.write("Paste check: transcript not in the field (\(lastCount) chars) after \(PasteCheck.reads) reads\(previousSeen ? "; the clipboard's previous text is" : "")")
    }

    private enum PasteCheck {
        /// Reads after `ReadBackTiming.settle`, for fields that update their
        /// accessibility text lazily.
        static let reads = 4
        static let retry: Duration = .milliseconds(300)
        /// Shorter previous clipboard text is too likely to be in the field
        /// already for its presence to mean anything.
        static let minimumClipboardChars = 8
    }
}

/// One paste, from the clipboard write to the restore.
///
/// The transcript is promised with `declareTypes(_:owner:)` rather than
/// written, so the pasteboard asks this object for it the first time any
/// process reads the string. That call is the receipt the restore waits
/// for: no fixed delay after Cmd+V can be right for both a native text view
/// that reads synchronously and an Electron app that reads hundreds of
/// milliseconds later. Later readers are served from the pasteboard's copy
/// without a second call, so there is exactly one receipt per paste.
///
/// The `org.nspasteboard` marker types tell clipboard managers not to read
/// or record the write; a manager that reads anyway takes the receipt
/// before Cmd+V, and the restore falls back to a timer.
@MainActor
final class PasteTransaction: NSObject, NSPasteboardTypeOwner {
    private static let markers = ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType"]
        .map { NSPasteboard.PasteboardType($0) }

    private let text: String
    private let saved: Output.Saved
    /// The pasteboard's change count after our write. Any other app taking
    /// the clipboard moves it.
    private var changeCount = 0
    private var ownershipLost = false
    private var chordAt: ContinuousClock.Instant?
    private var readAt: ContinuousClock.Instant?

    init(text: String, saved: Output.Saved) {
        self.text = text
        self.saved = saved
    }

    func publish(on pb: NSPasteboard) {
        changeCount = pb.declareTypes([.string] + Self.markers, owner: self)
        // Written now so only the string stays promised: a manager checking
        // the marker types must not count as the read.
        for marker in Self.markers { pb.setData(Data(), forType: marker) }
    }

    func chordPosted() {
        chordAt = .now
    }

    nonisolated func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
        sender.setString(text, forType: type)
        MainActor.assumeIsolated { markRead() }
    }

    private func markRead() {
        guard readAt == nil else { return }
        readAt = .now
        if let chordAt {
            DebugLog.write("Paste: clipboard read \((ContinuousClock.now - chordAt).milliseconds) ms after Cmd+V")
        } else {
            DebugLog.write("Paste: clipboard read before Cmd+V, by a clipboard manager or another reader")
        }
    }

    nonisolated func pasteboardChangedOwner(_ sender: NSPasteboard) {
        MainActor.assumeIsolated { ownershipLost = true }
    }

    /// `true` once the string has been read, `false` when it has not been
    /// by `ms` after Cmd+V.
    func read(within ms: Int) async -> Bool {
        guard let chordAt else { return false }
        while readAt == nil {
            let elapsed = (ContinuousClock.now - chordAt).milliseconds
            if elapsed >= ms { return false }
            try? await Task.sleep(for: .milliseconds(min(Fixed.pasteTickMs, ms - elapsed)))
        }
        return true
    }

    /// Waits for the read, posts Return when `submit` is given, then puts
    /// the clipboard back. Ends without restoring when another app has taken
    /// the clipboard or `isCurrent` says a newer paste replaced this one.
    func settle(posted: Bool, submit: (@MainActor () -> Void)?, isCurrent: @MainActor () -> Bool) async {
        let pb = NSPasteboard.general
        guard let chordAt else { return }
        var submitted = submit == nil
        while true {
            guard isCurrent() else { return }
            if pb.changeCount != changeCount || ownershipLost {
                DebugLog.write("Paste: another app took the clipboard (change \(changeCount) → \(pb.changeCount)) before the restore; it now holds \(Output.describe(pb)) and is left alone")
                return
            }
            let elapsed = (ContinuousClock.now - chordAt).milliseconds
            let readAfterMs = readAt.map { ($0 - chordAt).milliseconds }
            let plan = PasteTiming.plan(posted: posted, readAfterMs: readAfterMs)
            if !submitted, let submit, let at = plan.submitAfterMs, elapsed >= at {
                submit()
                submitted = true
            }
            if elapsed >= plan.restoreAfterMs { break }
            var wait = min(Fixed.pasteTickMs, plan.restoreAfterMs - elapsed)
            if !submitted, let at = plan.submitAfterMs { wait = min(wait, max(1, at - elapsed)) }
            try? await Task.sleep(for: .milliseconds(wait))
        }
        restore(on: pb)
        let read = switch readAt.map({ ($0 - chordAt).milliseconds }) {
        case .none: "never read"
        case .some(let ms) where ms < 0: "read before Cmd+V, so on a timer"
        case .some(let ms): "read after \(ms) ms"
        }
        DebugLog.write("Paste: clipboard put back \((ContinuousClock.now - chordAt).milliseconds) ms after Cmd+V (\(read))")
    }

    /// Puts the clipboard back now if it is still ours, for a paste that
    /// starts before this one settled.
    func abandon(on pb: NSPasteboard) {
        guard pb.changeCount == changeCount, !ownershipLost else { return }
        restore(on: pb)
        DebugLog.write("Paste: clipboard put back early, a new paste is starting")
    }

    private func restore(on pb: NSPasteboard) {
        pb.clearContents()
        switch saved {
        case .text(let text): pb.setString(text, forType: .string)
        case .image(let data, let type): pb.setData(data, forType: type)
        case .nothing: break
        }
    }
}

/// When the clipboard goes back and Return goes out, in milliseconds after
/// Cmd+V, given when the clipboard was read.
enum PasteTiming {
    struct Plan: Equatable {
        var restoreAfterMs: Int
        /// `nil`: no Return, whatever the setting says. Nothing read the
        /// clipboard, so nothing was pasted for Return to submit.
        var submitAfterMs: Int?
    }

    /// `readAfterMs` is when the string was first read, relative to Cmd+V:
    /// `nil` while unread; negative when something read it before the chord,
    /// which used up the one receipt, so the target's own read cannot be
    /// seen and a timer stands in.
    static func plan(posted: Bool, readAfterMs: Int?) -> Plan {
        guard posted else { return Plan(restoreAfterMs: Fixed.pasteNotPostedMs, submitAfterMs: nil) }
        guard let readAfterMs else { return Plan(restoreAfterMs: Fixed.pasteUnreadCapMs, submitAfterMs: nil) }
        if readAfterMs < 0 { return Plan(restoreAfterMs: Fixed.pasteReadEarlyMs, submitAfterMs: Fixed.pasteReadEarlyMs) }
        return Plan(restoreAfterMs: readAfterMs + Fixed.pasteQuietMs, submitAfterMs: readAfterMs + Fixed.autoSubmitDelayMs)
    }
}

extension Duration {
    var milliseconds: Int {
        Int(components.seconds * 1000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
