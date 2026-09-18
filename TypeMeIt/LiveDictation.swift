import Foundation

/// One dictation fed to the transcriber while it is still being spoken.
///
/// The tap hands samples over from the audio thread, which must not wait for
/// anything, so they go into a stream and a single task drains it into the
/// transcriber. One task means the chunks arrive in the order they were
/// recorded; separate tasks would not promise that.
///
/// A failure anywhere leaves `transcript()` throwing and the session reset.
/// The caller still holds the whole recording and can transcribe it offline,
/// so a stream that goes wrong costs time, never the dictation.
final class LiveDictation: Sendable {
    private let feed: AsyncStream<[Float]>.Continuation
    private let pump: Task<Transcriber.Transcript, Error>

    init() {
        let (inbox, feed) = AsyncStream<[Float]>.makeStream(of: [Float].self)
        self.feed = feed
        pump = Task {
            try await Transcriber.shared.beginStream()
            for await chunk in inbox {
                try Task.checkCancellation()
                try await Transcriber.shared.feedStream(chunk)
            }
            try Task.checkCancellation()
            return try await Transcriber.shared.finishStream()
        }
    }

    /// Safe to call from the audio thread.
    func append(_ pcm: [Float]) { feed.yield(pcm) }

    /// Closes the stream and waits for the transcript the feeder produces
    /// from everything appended so far.
    func transcript() async throws -> Transcriber.Transcript {
        feed.finish()
        return try await pump.value
    }

    func cancel() {
        feed.finish()
        pump.cancel()
        Task { await Transcriber.shared.endStream() }
    }
}
