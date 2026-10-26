import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// What the pipeline hears from the keyboard.
enum ShortcutEvent: Sendable {
    case recordingStarted
    case pinned
    case recordingEnded
    case cancelled
    /// The user's copy-last-transcript shortcut, while idle.
    case copyLastRequested
    /// The user's record-the-room shortcut, while idle: starts a room
    /// recording, or stops the one running.
    case roomRequested
}

/// One CGEvent tap. Fn is keycode 63 on flagsChanged. Space (49) and Esc
/// (53) are watched only while a recording is in progress, Return (36, and
/// Enter on the keypad, 76) only while `onReturn` takes it. Where the tap is
/// not allowed (`Sandbox.watchesFn`), system hotkeys stand in and the
/// combo's modifiers play Fn: the combo starts a recording, which lasts
/// while its modifiers are held; space with them pins, the combo finishes a
/// pinned recording, and Esc cancels. Return is not taken there.
@MainActor
final class Shortcuts {
    enum Phase: Sendable { case idle, recording, pinned, transcribing, cleaningUp }

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { phaseChanged() } }
    }
    private(set) var tapInstalled = false
    var onEvent: (@MainActor (ShortcutEvent) -> Void)?
    /// A plain Return while idle: answers the prompt waiting for it and says
    /// whether it did, in which case the key never reaches the app underneath.
    var onReturn: (@MainActor () -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnIsDown = false
    private var fnSeenUp = false
    private var fnDownAt: ContinuousClock.Instant?
    /// The Return whose key down `onReturn` took, so its key up is kept too.
    private var swallowingReturn = false
    private var hotKeys: HotKeys?
    /// Set while a shortcut recorder is listening, so the combos it is
    /// shown reach it instead of starting a dictation.
    private var hotKeysPaused = false
    /// While a hotkey recording is held: checks whether the combo's
    /// modifiers are still down, since a hotkey reports no modifier changes.
    private var holdPoll: Timer?
    /// The combo's key has come up since it started the recording, so a
    /// press now is space again rather than the key repeating.
    private var comboKeyUp = false

    private static let fnKeycode: Int64 = 63
    private static let spaceKeycode: Int64 = 49
    private static let escKeycode: Int64 = 53
    private static let returnKeycodes: Set<Int64> = [36, 76]

    /// Returns false when Accessibility has not been granted.
    @discardableResult
    func install() -> Bool {
        if !Sandbox.watchesFn { return installHotKeys() }
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Shortcuts.callback, userInfo: userInfo)
        else {
            Log.shortcuts.error("Event tap could not be created; Accessibility is missing")
            tapInstalled = false
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapInstalled = true
        // Ignore an Fn that was already held when the tap appeared.
        fnSeenUp = !CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        Log.shortcuts.info("Event tap installed")
        return true
    }

    private func installHotKeys() -> Bool {
        guard hotKeys == nil else { return true }
        let hotKeys = HotKeys()
        guard hotKeys.install() else {
            Log.shortcuts.error("Hotkey handler could not be installed")
            return false
        }
        hotKeys.onKey = { [weak self] key, down in self?.handle(key, down: down) }
        self.hotKeys = hotKeys
        fnSeenUp = true
        registerHotKeys()
        Log.shortcuts.info("Hotkeys installed")
        return true
    }

    /// Registers the combos from settings, and again whenever they change.
    private func registerHotKeys() {
        guard let hotKeys else { return }
        withObservationTracking {
            let dictate = Settings.shared.dictationShortcut
            let copyLast = Settings.shared.copyLastShortcut
            let recordRoom = Settings.shared.recordRoomShortcut
            hotKeys.set(.dictate, to: hotKeysPaused ? nil : dictate)
            hotKeys.set(.copyLast, to: hotKeysPaused ? nil : copyLast)
            hotKeys.set(.recordRoom, to: hotKeysPaused || !Sandbox.hasMeetings ? nil : recordRoom)
        } onChange: {
            Task { @MainActor [weak self] in self?.registerHotKeys() }
        }
    }

    /// A shortcut recorder is listening, or has stopped.
    func pauseHotKeys(_ paused: Bool) {
        guard hotKeys != nil, paused != hotKeysPaused else { return }
        hotKeysPaused = paused
        registerHotKeys()
    }

    /// Esc is taken from other apps only while there is something to
    /// cancel, and space with the combo's modifiers only while held.
    private func phaseChanged() {
        guard let hotKeys else { return }
        hotKeys.set(.cancel, to: phase == .idle ? nil : .escape)
        let combo = Settings.shared.dictationShortcut
        let pin = KeyCombo.space(with: combo.modifiers)
        // When the combo is itself space with modifiers, its own press pins.
        hotKeys.set(.pin, to: phase == .recording && pin != combo ? pin : nil)
        if phase == .recording {
            let poll = Timer(timeInterval: Fixed.holdPollMs / 1000, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkHold() }
            }
            RunLoop.main.add(poll, forMode: .common)
            holdPoll = poll
        } else {
            holdPoll?.invalidate()
            holdPoll = nil
        }
    }

    /// Letting go of the combo's modifiers is letting go of Fn.
    private func checkHold() {
        let held = KeyCombo.Modifiers(CGEventSource.flagsState(.combinedSessionState))
        if !held.isSuperset(of: Settings.shared.dictationShortcut.modifiers) { fnUp() }
    }

    private func handle(_ key: HotKeys.Key, down: Bool) {
        switch key {
        case .dictate:
            guard down else { comboKeyUp = true; return }
            if phase == .recording {
                if comboKeyUp { pinWhileHeld() }
            } else {
                comboKeyUp = false
                fnDown()
            }
        case .pin:
            if down, phase == .recording { pinWhileHeld() }
        case .cancel:
            guard down, phase != .idle else { return }
            phase = .idle
            onEvent?(.cancelled)
        case .copyLast:
            if down, phase == .idle { onEvent?(.copyLastRequested) }
        case .recordRoom:
            if down, phase == .idle { onEvent?(.roomRequested) }
        }
    }

    func uninstall() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        runLoopSource = nil
        tapInstalled = false
    }

    /// The key held to dictate, as running text names it.
    static var holdKeyName: String { Sandbox.watchesFn ? "fn" : Settings.shared.dictationShortcut.inline }

    /// The pipeline tells the shortcuts where it is so Esc means the right thing.
    func setPhase(_ p: Phase) { phase = p }

    /// The pill's pin button.
    func pinFromOverlay() {
        guard phase == .recording else { return }
        phase = .pinned
        onEvent?(.pinned)
    }

    /// The pill's stop button while pinned.
    func stopFromOverlay() {
        guard phase == .pinned else { return }
        phase = .transcribing
        onEvent?(.recordingEnded)
    }

    /// The menu's Start Recording. Opens the microphone already pinned, since
    /// there is no key to release.
    func startFromMenu() {
        guard phase == .idle else { return }
        phase = .pinned
        onEvent?(.recordingStarted)
        onEvent?(.pinned)
    }

    /// The menu's Stop Recording, whether the recording was pinned or Fn is
    /// still held.
    func stopFromMenu() {
        guard phase == .recording || phase == .pinned else { return }
        phase = .transcribing
        onEvent?(.recordingEnded)
    }

    /// An Option-click on the menu bar puff: starts a recording the way the
    /// menu does, or stops the one in progress. False when neither applies,
    /// so the click can open the menu instead.
    func toggleFromMenuBar() -> Bool {
        switch phase {
        case .idle: startFromMenu()
        case .recording, .pinned: stopFromMenu()
        case .transcribing, .cleaningUp: return false
        }
        return true
    }

    func cancelFromOverlay() {
        guard phase != .idle else { return }
        phase = .idle
        onEvent?(.cancelled)
    }

    private struct EventBox: @unchecked Sendable { let event: CGEvent }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let shortcuts = Unmanaged<Shortcuts>.fromOpaque(userInfo).takeUnretainedValue()
        let box = EventBox(event: event)
        // The tap's run loop source lives on the main run loop, so this runs on the main thread.
        let passThrough = MainActor.assumeIsolated { shortcuts.handle(type: type, event: box.event) }
        return passThrough ? Unmanaged.passUnretained(event) : nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            DebugLog.write("Shortcuts: event tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"), re-enabled; Fn was \(fnIsDown ? "down" : "up")")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Shortcuts.fnKeycode else {
                return true
            }
            let down = event.flags.contains(.maskSecondaryFn)
            if down != fnIsDown {
                fnIsDown = down
                if down { fnDown() } else { fnUp() }
            }
            return true
        case .keyDown, .keyUp:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if phase == .idle, let combo = Settings.shared.copyLastShortcut, combo.matches(keyCode: keycode, flags: event.flags) {
                if type == .keyDown { onEvent?(.copyLastRequested) }
                return false  // swallow both so the key does not also reach the app underneath
            }
            if phase == .idle, let combo = Settings.shared.recordRoomShortcut, combo.matches(keyCode: keycode, flags: event.flags) {
                if type == .keyDown { onEvent?(.roomRequested) }
                return false
            }
            if keycode == Shortcuts.spaceKeycode, fnIsDown || phase == .pinned, phase == .recording || phase == .pinned {
                if type == .keyDown, phase == .recording {
                    phase = .pinned
                    onEvent?(.pinned)
                }
                return false  // swallow both down and up so no space reaches the app underneath
            }
            if Shortcuts.returnKeycodes.contains(keycode) {
                let plain = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
                if type == .keyDown, phase == .idle, plain, onReturn?() == true {
                    swallowingReturn = true
                    return false
                }
                if type == .keyUp, swallowingReturn {
                    swallowingReturn = false
                    return false
                }
            }
            if keycode == Shortcuts.escKeycode, type == .keyDown {
                switch phase {
                case .recording, .pinned, .transcribing, .cleaningUp:
                    phase = .idle
                    onEvent?(.cancelled)
                    return false
                case .idle:
                    break
                }
            }
            return true
        default:
            return true
        }
    }

    private func pinWhileHeld() {
        phase = .pinned
        onEvent?(.pinned)
    }

    private func fnDown() {
        guard fnSeenUp else { return }
        switch phase {
        case .idle:
            fnDownAt = .now
            phase = .recording
            onEvent?(.recordingStarted)
        case .pinned:
            phase = .transcribing
            onEvent?(.recordingEnded)
        default:
            break
        }
    }

    private func fnUp() {
        fnSeenUp = true
        switch phase {
        case .recording:
            let held = fnDownAt.map { ContinuousClock.now - $0 } ?? .zero
            if held < .milliseconds(Fixed.holdThresholdMs) {
                phase = .idle
                onEvent?(.cancelled)  // a tap
            } else {
                phase = .transcribing
                onEvent?(.recordingEnded)
            }
        case .pinned:
            break  // the release is ignored while pinned
        default:
            break
        }
    }
}

/// System hotkeys through Carbon's `RegisterEventHotKey`, which needs no
/// permission. A registered combo is taken from every app, press and
/// release, until it is unregistered.
@MainActor
private final class HotKeys {
    enum Key: UInt32 { case dictate = 1, pin, cancel, copyLast, recordRoom }

    var onKey: (@MainActor (Key, _ down: Bool) -> Void)?
    private var handler: EventHandlerRef?
    private var registered: [Key: EventHotKeyRef] = [:]

    nonisolated private static let signature: OSType = "tmit".utf8.reduce(0) { $0 << 8 | OSType($1) }

    func install() -> Bool {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        return InstallEventHandler(GetEventDispatcherTarget(), HotKeys.callback, types.count, &types, userInfo, &handler) == noErr
    }

    /// Registers `combo` for `key`, replacing what `key` had; nil leaves it
    /// unregistered.
    func set(_ key: Key, to combo: KeyCombo?) {
        if let ref = registered.removeValue(forKey: key) { UnregisterEventHotKey(ref) }
        guard let combo else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: HotKeys.signature, id: key.rawValue)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            registered[key] = ref
        } else {
            Log.shortcuts.error("Hotkey \(combo.inline) could not be registered: \(status)")
        }
    }

    private static let callback: EventHandlerUPP = { _, event, userInfo in
        guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == HotKeys.signature, let key = Key(rawValue: id.id) else {
            return OSStatus(eventNotHandledErr)
        }
        let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        let hotKeys = Unmanaged<HotKeys>.fromOpaque(userInfo).takeUnretainedValue()
        // Carbon dispatches on the main run loop.
        MainActor.assumeIsolated { hotKeys.onKey?(key, down) }
        return noErr
    }
}
