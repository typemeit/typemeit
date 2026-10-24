import CryptoKit
import FluidAudio
import Foundation
import Observation

/// Downloads and locates the one speech model the app uses: Parakeet Ultra's
/// Core ML files in one hash-pinned tar from typeme.it's release bucket,
/// untarred to `directory` and loaded from there by `Transcriber`. A new model
/// is a new `version` and tar; the upgrade panel and the onboarding step read
/// the name, the reason and the size from here. `make asr-model-sums` prints
/// the constants.
@MainActor
@Observable
final class ModelStore: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()

    /// Names the folder under `asrDirectory`, a meeting's `transcription.asr` and `Settings.speechModelVersion`.
    nonisolated static let version = "parakeet-ultra-95eaa59a"
    /// What the upgrade panel and the onboarding row call it.
    nonisolated static let displayName = "speech model"
    nonisolated static let upgradeTitle = "a faster speech model"
    /// Why a person on an older model is asked to download this one.
    nonisolated static let upgradeReason = "dictation is about 3× faster, uses a quarter of the memory, and leaves your graphics card free during meetings."
    nonisolated static let fileName = "parakeet-ultra-95eaa59a.tar"
    nonisolated static let expectedBytes: Int64 = 632_186_880
    nonisolated static let sha256 = "6b3a3cd5220c9597e50c12049384d18fb326ef0eee03b54a83bc05b87ca0cb04"
    nonisolated static var downloadURL: URL {
        #if DEBUG
        // Serves a locally built tar to a debug build before it is published.
        if let override = ProcessInfo.processInfo.environment["TYPEMEIT_MODEL_URL"], let url = URL(string: override) { return url }
        #endif
        return URL(string: "https://typeme.it/models/\(fileName)")!
    }

    nonisolated static let modelsDirectory = SupportPaths.directory.appendingPathComponent("models", isDirectory: true)
    /// One folder per speech model version.
    nonisolated static let asrDirectory = modelsDirectory.appendingPathComponent("asr", isDirectory: true)
    /// What `AsrModels.loadLocal(from:version:)` reads.
    nonisolated static let directory = asrDirectory.appendingPathComponent(version, isDirectory: true)
    /// The models and vocabulary `loadLocal` opens, relative to `directory`.
    nonisolated static let requiredFiles = [ModelNames.ASR.preprocessorFile, ModelNames.ASR.encoderFile, ModelNames.ASR.decoderFile,
                                            ModelNames.ASR.jointV3File, ModelNames.ASR.vocabularyFile]
    /// The Parakeet GGUF earlier releases ran on transcribe.cpp.
    nonisolated static let legacyModelURL = modelsDirectory.appendingPathComponent("parakeet-unified-en-0.6b-Q8_0.gguf")
    private nonisolated static let partialURL = modelsDirectory.appendingPathComponent("download.partial")

    /// The size as the panel and the onboarding row show it.
    nonisolated static func sizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file).lowercased()
    }

    /// Someone who finished onboarding on a model that is no longer the
    /// current one has to download it before dictating. A first run goes
    /// through onboarding instead.
    nonisolated static func needsUpgrade(onboardingComplete: Bool, currentInstalled: Bool) -> Bool {
        onboardingComplete && !currentInstalled
    }

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
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// Called once the installed model has loaded: it is recorded as the
    /// installed version, and what it replaced is deleted. Nothing is deleted
    /// before then, so a model that fails to load leaves the old one on disk.
    func modelLoaded() {
        Settings.shared.speechModelVersion = ModelStore.version
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: ModelStore.legacyModelURL)
        let folders = (try? fileManager.contentsOfDirectory(at: ModelStore.asrDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent != ModelStore.version { try? fileManager.removeItem(at: folder) }
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
        let staging = ModelStore.partialURL
        try? FileManager.default.removeItem(at: staging)
        do { try FileManager.default.moveItem(at: location, to: staging) } catch {
            Task { @MainActor in self.fail("Could not save the download: \(error.localizedDescription)") }
            return
        }
        Task { @MainActor in
            self.task = nil
            self.reconnecting = false
            self.state = .verifying
            let installed = await ModelStore.install(staging)
            try? FileManager.default.removeItem(at: staging)
            switch installed {
            case .success:
                Settings.shared.speechModelVersion = ModelStore.version
                self.state = .installed
                self.endActivity()
                Log.model.info("Model installed")
                Task { await Transcriber.shared.preload() }
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

    /// Hash-checks and untars in a scratch directory, then moves the folder
    /// into place with one rename. Anything that fails before the move
    /// leaves the models directory as it was.
    private nonisolated static func install(_ tar: URL) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let scratch = modelsDirectory.appendingPathComponent("unpacking-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: scratch) }
            do {
                guard try matchesChecksum(tar) else { throw InstallError.checksum }
                try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
                let untar = Process()
                untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                untar.arguments = ["-xf", tar.path, "-C", scratch.path]
                try untar.run()
                untar.waitUntilExit()
                guard untar.terminationStatus == 0 else { throw InstallError.untar(untar.terminationStatus) }
                let unpacked = scratch.appendingPathComponent(version, isDirectory: true)
                guard requiredFiles.allSatisfy({ fileManager.fileExists(atPath: unpacked.appendingPathComponent($0).path) }) else { throw InstallError.incomplete }
                try fileManager.createDirectory(at: asrDirectory, withIntermediateDirectories: true)
                try? fileManager.removeItem(at: directory)
                try fileManager.moveItem(at: unpacked, to: directory)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
    }

    private nonisolated static func matchesChecksum(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256
    }
}
