import Testing
@testable import TypeMeIt

@MainActor
struct ShortcutsTests {
    let shortcuts = Shortcuts()

    private func events(during body: () -> Void) -> [ShortcutEvent] {
        var seen: [ShortcutEvent] = []
        shortcuts.onEvent = { seen.append($0) }
        body()
        return seen
    }

    @Test func menuBarToggleStartsPinnedWhileIdle() {
        var handled = false
        let seen = events { handled = shortcuts.toggleFromMenuBar() }
        #expect(handled)
        #expect(seen == [.recordingStarted, .pinned])
        #expect(shortcuts.phase == .pinned)
    }

    @Test func menuBarToggleStopsARecording() {
        shortcuts.setPhase(.recording)
        var handled = false
        let seen = events { handled = shortcuts.toggleFromMenuBar() }
        #expect(handled)
        #expect(seen == [.recordingEnded])
        #expect(shortcuts.phase == .ending)
    }

    @Test func menuBarToggleDoesNothingWhileTranscribing() {
        for phase in [Shortcuts.Phase.ending, .transcribing, .cleaningUp] {
            shortcuts.setPhase(phase)
            var handled = true
            let seen = events { handled = shortcuts.toggleFromMenuBar() }
            #expect(!handled)
            #expect(seen.isEmpty)
            #expect(shortcuts.phase == phase)
        }
    }

    @Test func thePhaseMovesBeforeItsEventIsSent() {
        var log: [String] = []
        shortcuts.onPhaseChanged = { log.append("phase \($0)") }
        shortcuts.onEvent = { log.append("event \($0)") }
        shortcuts.startFromMenu()
        #expect(log == ["phase pinned", "event recordingStarted", "event pinned"])
    }

    @Test func aPinnedStopEndsThroughTheTail() {
        shortcuts.startFromMenu()
        let seen = events { shortcuts.stopFromOverlay() }
        #expect(seen == [.recordingEnded])
        #expect(shortcuts.phase == .ending)
        #expect(shortcuts.phase.isCapturing)
    }
}
