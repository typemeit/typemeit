// Timings of the "Learned words" toast on the recording overlay.

import Foundation

enum ToastTiming {
    /// How long the toast stays on screen before the frontend dismisses it.
    /// The frontend owns the real countdown so hovering the pill can pause it.
    static let timeout: Duration = .seconds(8)

    /// Backstop hide scheduled in case the frontend never dismisses (for
    /// example while the pill is left hovered).
    static let safetyHide: Duration = .seconds(60)

    /// How long the "Undone" confirmation stays visible after a click.
    static let undoneLinger: Duration = .milliseconds(900)

    /// How often a countdown checks whether its toast still counts.
    static let countdownStep: Duration = .milliseconds(100)

    /// Counts `length` down a step at a time, only the steps after which
    /// `counting` holds (its toast is on screen and not hovered), and stops
    /// anyway once `deadline` has passed in steps. `counting` gives nil once
    /// what owns the toast is gone.
    /// - Returns: false when the task was cancelled or the owner went first.
    @MainActor
    static func countDown(_ length: Duration = timeout, deadline: Duration? = safetyHide, counting: () -> Bool?,
                          sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async -> Bool {
        var remaining = length
        var elapsed: Duration = .zero
        while remaining > .zero, deadline.map({ elapsed < $0 }) ?? true {
            await sleep(countdownStep)
            elapsed += countdownStep
            guard !Task.isCancelled, let counts = counting() else { return false }
            if counts { remaining -= countdownStep }
        }
        return !Task.isCancelled
    }
}
