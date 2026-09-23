import CryptoKit
import Foundation
import Observation

/// Downloads and locates the one speech model the app uses.
@MainActor
@Observable
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()

    nonisolated static let fileName = "parakeet-unified-en-0.6b-Q8_0.gguf"
    nonisolated static let expectedBytes: Int64 = 731_357_568
    nonisolated static let sha256 = "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795"
    nonisolated static let downloadURL = URL(string: "https://github.com/typemeit/typemeit/releases/download/model-parakeet-unified-en-0.6b-q8_0/parakeet-unified-en-0.6b-Q8_0.gguf")!

    nonisolated static let modelsDirectory = Store.directory.appendingPathComponent("models", isDirectory: true)
    nonisolated static let modelURL = modelsDirectory.appendingPathComponent(fileName)

    enum State: Equatable, Sendable {
        case missing
        case downloading(received: Int64, total: Int64)
        case verifying
        case failed(String)
        case installed
    }

    private(set) var state: State
    /// The connection stalled or dropped and the download is picking up
    /// where it stopped.
    private(set) var reconnecting = false
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    /// Retries since the last byte arrived.
    private var retries = 0
    private var lastPublished: Int64 = 0
    /// Keeps App Nap from throttling the download while the window is hidden.
    private var activity: NSObjectProtocol?
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = ModelStore.stallTimeout
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// Seconds without a byte before the connection counts as stalled.
    private static let stallTimeout: TimeInterval = 15
    /// Stalls in a row, with no progress between them, before the download fails.
    private static let maxRetries = 5
    private static let retryDelay: Duration = .seconds(2)
    /// The progress bar moves at most once per this many bytes.
    private static let publishStep: Int64 = 1 << 20

    private override init() {
        try? FileManager.default.createDirectory(at: ModelStore.modelsDirectory, withIntermediateDirectories: true)
        state = ModelStore.isInstalled ? .installed : .missing
        super.init()
    }

    nonisolated static var isInstalled: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size == expectedBytes
    }

    /// Starts or resumes the download. Only ever called from a button the
    /// user pressed next to the download size.
    func download() {
        guard task == nil, state != .installed else { return }
        retries = 0
        state = .downloading(received: 0, total: ModelStore.expectedBytes)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Downloading the speech model")
        }
        start()
    }

    func cancel() {
        reconnecting = false
        endActivity()
        guard let task else { state = .missing; return }
        task.cancel { [weak self] data in
            Task { @MainActor in
                self?.resumeData = data
                self?.task = nil
                self?.state = .missing
            }
        }
    }

    private func start() {
        lastPublished = 0
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
            self.resumeData = nil
        } else {
            task = session.downloadTask(with: ModelStore.downloadURL)
        }
        task?.resume()
    }

    /// Picks the download up again after a stall or a dropped connection,
    /// unless the user cancelled in the meantime.
    private func retry(fresh: Bool) {
        task = nil
        if fresh { resumeData = nil }
        guard retries < ModelStore.maxRetries else {
            fail("The download stopped. Check your connection and try again.")
            return
        }
        retries += 1
        reconnecting = true
        Log.model.info("Model download retry \(self.retries), fresh: \(fresh)")
        Task { @MainActor in
            try? await Task.sleep(for: ModelStore.retryDelay)
            guard case .downloading = state, task == nil else { return }
            start()
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            retries = 0
            reconnecting = false
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : ModelStore.expectedBytes
            guard totalBytesWritten - lastPublished >= ModelStore.publishStep || totalBytesWritten >= total else { return }
            lastPublished = totalBytesWritten
            state = .downloading(received: totalBytesWritten, total: total)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // A resume on the signed asset URL after it expires, or any other
        // error page, arrives here as a finished download of the error body.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            MainActor.assumeIsolated {
                Log.model.error("Model download got HTTP \(http.statusCode)")
                retry(fresh: true)
            }
            return
        }
        // Move out of the temporary location synchronously; it is deleted when this returns.
        let staging = ModelStore.modelsDirectory.appendingPathComponent("download.partial")
        try? FileManager.default.removeItem(at: staging)
        do { try FileManager.default.moveItem(at: location, to: staging) } catch {
            Task { @MainActor in self.fail("Could not save the download: \(error.localizedDescription)") }
            return
        }
        Task { @MainActor in
            self.task = nil
            self.reconnecting = false
            self.state = .verifying
            let ok = await ModelStore.verify(staging)
            if ok {
                try? FileManager.default.removeItem(at: ModelStore.modelURL)
                do {
                    try FileManager.default.moveItem(at: staging, to: ModelStore.modelURL)
                    self.state = .installed
                    self.endActivity()
                    Log.model.info("Model installed")
                    Task { await Transcriber.shared.preload() }
                } catch {
                    self.fail("Could not move the model into place: \(error.localizedDescription)")
                }
            } else {
                try? FileManager.default.removeItem(at: staging)
                self.fail("The downloaded file did not match its checksum.")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        MainActor.assumeIsolated {
            Log.model.error("Model download interrupted: \(error.localizedDescription)")
            resumeData = resume
            retry(fresh: false)
        }
    }

    private func fail(_ message: String) {
        task = nil
        reconnecting = false
        state = .failed(message)
        endActivity()
        Log.model.error("Model download failed: \(message)")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private nonisolated static func verify(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return digest == sha256
        }.value
    }
}
