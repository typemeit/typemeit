import AppKit
import CoreGraphics
import Foundation

/// Pastes through the clipboard with Cmd+V and restores what was there.
@MainActor
enum Output {
    private static func post(keycode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func sleep(ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// Returns false when the key events could not be posted (Accessibility missing).
    static func paste(_ text: String, autoSubmit: Bool, autoSubmitKey: AutoSubmitKey) async -> Bool {
        let pb = NSPasteboard.general
        let savedText = pb.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
        let savedImage: (Data, NSPasteboard.PasteboardType)? = savedText == nil
            ? ([NSPasteboard.PasteboardType.tiff, .png].lazy.compactMap { t in pb.data(forType: t).map { ($0, t) } }.first)
            : nil

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Anyone else writing to the clipboard before the restore moves this.
        let ourChange = pb.changeCount
        await sleep(ms: Fixed.pasteDelayBeforeMs)

        let posted = post(keycode: 9, flags: .maskCommand)  // V
        let postedAt = ContinuousClock.now
        if !posted { Log.output.error("Could not post Cmd+V; Accessibility may be missing") }
        DebugLog.write("Paste: Cmd+V \(posted ? "posted" : "not posted") to \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "no frontmost app") with \(text.count) chars \"\(DebugLog.excerpt(text))\" on the clipboard, which held \(savedText.map { "text (\($0.count) chars)" } ?? (savedImage == nil ? "nothing" : "an image")); accessibility \(AXIsProcessTrusted() ? "granted" : "missing"); secure input \(SecureInput.owner.map { "held by \($0.name)" } ?? "off")")

        await sleep(ms: Fixed.pasteDelayAfterMs)
        if pb.changeCount != ourChange {
            DebugLog.write("Paste: another app rewrote the clipboard before the restore (change \(ourChange) → \(pb.changeCount)); it now holds \(describe(pb))")
        }
        pb.clearContents()
        if let savedText {
            pb.setString(savedText, forType: .string)
        } else if let (data, type) = savedImage {
            pb.setData(data, forType: type)
        }
        DebugLog.write("Paste: clipboard put back \((ContinuousClock.now - postedAt).milliseconds) ms after Cmd+V")

        if posted, autoSubmit {
            await sleep(ms: Fixed.autoSubmitDelayMs)
            let flags: CGEventFlags = switch autoSubmitKey {
            case .enter: []
            case .ctrlEnter: .maskControl
            case .cmdEnter: .maskCommand
            }
            _ = post(keycode: 36, flags: flags)  // Return
        }
        if posted, DebugLog.enabled {
            if autoSubmit {
                DebugLog.write("Paste check skipped: auto submit is on")
            } else {
                Task { await checkLanded(text, previousClipboard: savedText) }
            }
        }
        return posted
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func describe(_ pb: NSPasteboard) -> String {
        if let s = pb.string(forType: .string) { return "text (\(s.count) chars)" }
        if pb.data(forType: .tiff) != nil || pb.data(forType: .png) != nil { return "an image" }
        return "nothing"
    }

    // MARK: Debug logs

    /// Reads the focused field back a moment after the paste and logs whether
    /// the transcript is there, or the clipboard's previous text is instead:
    /// the sign of the target app taking Cmd+V after the clipboard was put
    /// back. Only the verdict is logged; the field's text is never written
    /// out. Skipped where the read-back is: password fields and the apps on
    /// its denylist.
    private static func checkLanded(_ text: String, previousClipboard: String?) async {
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
            if let previous = previousClipboard, previous.count >= PasteCheck.minimumClipboardChars,
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

extension Duration {
    var milliseconds: Int {
        Int(components.seconds * 1000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
