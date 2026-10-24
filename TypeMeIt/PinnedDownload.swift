import CryptoKit
import Foundation
import Observation
import OSLog

/// Downloads one hash-pinned tar from typeme.it's release bucket, checks it,
/// untars it in a scratch folder and moves its folders into place, so an
/// interrupted or failed download leaves the installed models as they were.
/// `ModelStore` and `DiarizerModelStore` are the two tars.
@MainActor
@Observable
class PinnedDownload: NSObject, URLSessionDownloadDelegate {
    struct Spec: Sendable {
        /// Names it in log lines: "speech model".
        var name: String
        var url: URL
        var expectedBytes: Int64
        var sha256: String
        /// Holds the download and the scratch folder. On the destinations'
        /// volume, so moving into place is a rename.
        var workDirectory: URL
        /// What the tar must hold, relative to its root.
        var requiredFiles: [String]
        /// Each top-level folder in the tar and where it is installed.
        var folders: [Folder]
        var log: Logger

        struct Folder: Sendable {
            var name: String
            var destination: URL
        }
    }

    enum State: Equatable, Sendable {
        case missing
        case downloading(received: Int64, total: Int64)
        case verifying
        case failed(String)
        case installed
    }

    /// Stalls or dropped connections in a row, with no progress between them, before the download fails.
    static let maxRetries = 5
    static let stoppedMessage = "The download stopped. Check your connection and try again."
    /// Seconds without a byte before the connection counts as stalled.
    private static let stallTimeout: TimeInterval = 15
    /// The progress bar moves at most once per this many bytes.
    private static let publishStep: Int64 = 1 << 20

    nonisolated let spec: Spec
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
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let configuration: URLSessionConfiguration
    @ObservationIgnored private lazy var session: URLSession = {
        configuration.timeoutIntervalForRequest = PinnedDownload.stallTimeout
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    init(spec: Spec, installed: Bool, configuration: URLSessionConfiguration = .default, retryDelay: Duration = .seconds(2)) {
        self.spec = spec
        self.configuration = configuration
        self.retryDelay = retryDelay
        state = installed ? .installed : .missing
        super.init()
    }

    /// Runs once the folders are in place.
    func didInstall() {}

    /// Starts or resumes the download. Only ever called from a button the
    /// user pressed next to the download size, or for a meeting that needs it.
    func download() {
        guard task == nil, state != .installed else { return }
        retries = 0
        state = .downloading(received: 0, total: spec.expectedBytes)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Downloading the \(spec.name)")
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
            task = session.downloadTask(with: spec.url)
        }
        task?.resume()
    }

    /// Picks the download up again after a stall, a dropped connection or
    /// an error page, unless the user cancelled in the meantime.
    private func retry(fresh: Bool) {
        task = nil
        if fresh { resumeData = nil }
        guard retries < PinnedDownload.maxRetries else {
            fail(PinnedDownload.stoppedMessage)
            return
        }
        retries += 1
        reconnecting = true
        spec.log.info("\(self.spec.name, privacy: .public) download retry \(self.retries), fresh: \(fresh)")
        Task { @MainActor in
            try? await Task.sleep(for: retryDelay)
            guard case .downloading = state, task == nil else { return }
            start()
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            retries = 0
            reconnecting = false
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : spec.expectedBytes
            guard totalBytesWritten - lastPublished >= PinnedDownload.publishStep || totalBytesWritten >= total else { return }
            lastPublished = totalBytesWritten
            state = .downloading(received: totalBytesWritten, total: total)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // A resume on the signed asset URL after it expires, or any other
        // error page, arrives here as a finished download of the error body.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            MainActor.assumeIsolated {
                spec.log.error("\(self.spec.name, privacy: .public) download got HTTP \(http.statusCode)")
                retry(fresh: true)
            }
            return
        }
        // Move out of the temporary location synchronously; it is deleted when this returns.
        let staging = spec.workDirectory.appendingPathComponent("\(spec.url.lastPathComponent).partial")
        do {
            try FileManager.default.createDirectory(at: spec.workDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            Task { @MainActor in self.fail("Could not save the download: \(error.localizedDescription)") }
            return
        }
        Task { @MainActor in
            self.task = nil
            self.reconnecting = false
            self.state = .verifying
            let installed = await PinnedDownload.install(staging, spec: spec)
            try? FileManager.default.removeItem(at: staging)
            switch installed {
            case .success:
                self.state = .installed
                self.endActivity()
                self.spec.log.info("\(self.spec.name, privacy: .public) installed")
                self.didInstall()
            case .failure(let error):
                self.fail(error.localizedDescription)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        MainActor.assumeIsolated {
            spec.log.error("\(self.spec.name, privacy: .public) download interrupted: \(error.localizedDescription)")
            resumeData = resume
            retry(fresh: false)
        }
    }

    private func fail(_ message: String) {
        task = nil
        reconnecting = false
        state = .failed(message)
        endActivity()
        spec.log.error("\(self.spec.name, privacy: .public) download failed: \(message)")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    enum InstallError: LocalizedError {
        case checksum, untar(Int32), incomplete
        var errorDescription: String? {
            switch self {
            case .checksum: "The downloaded file did not match its checksum."
            case .untar(let code): "The archive could not be unpacked (\(code))."
            case .incomplete: "The archive is missing model files."
            }
        }
    }

    /// Hash-checks and untars in a scratch folder, then moves each folder
    /// into place with one rename. Anything that fails before the moves
    /// leaves the installed folders as they were.
    private nonisolated static func install(_ tar: URL, spec: Spec) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let scratch = spec.workDirectory.appendingPathComponent("unpacking-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: scratch) }
            do {
                guard try matchesChecksum(tar, sha256: spec.sha256) else { throw InstallError.checksum }
                try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
                let untar = Process()
                untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                untar.arguments = ["-xf", tar.path, "-C", scratch.path]
                try untar.run()
                untar.waitUntilExit()
                guard untar.terminationStatus == 0 else { throw InstallError.untar(untar.terminationStatus) }
                guard spec.requiredFiles.allSatisfy({ fileManager.fileExists(atPath: scratch.appendingPathComponent($0).path) }) else { throw InstallError.incomplete }
                for folder in spec.folders {
                    try fileManager.createDirectory(at: folder.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fileManager.removeItem(at: folder.destination)
                    try fileManager.moveItem(at: scratch.appendingPathComponent(folder.name, isDirectory: true), to: folder.destination)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
    }

    private nonisolated static func matchesChecksum(_ url: URL, sha256: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256
    }
}
