import CryptoKit
import Foundation
import Observation

/// Downloads and locates the speaker model: one tar of the offline
/// diarizer's files, hash-pinned, from a release of this repo
/// (docs/meetings.md 8.2). Modelled on `ModelStore`. The download lands in
/// a temporary directory, is hash-checked and untarred there, and moved
/// into place with one rename, so an interrupted download leaves nothing
/// behind. `make diarizer-model-sums` prints the constants.
@MainActor
@Observable
final class DiarizerModelStore: NSObject, URLSessionDownloadDelegate {
    static let shared = DiarizerModelStore()

    nonisolated static let fileName = "speaker-diarization-df2625ac.tar"
    nonisolated static let expectedBytes: Int64 = 21_647_360
    nonisolated static let sha256 = "a04dfde71528d22ef0480b7c48fd0683957cf9267569b0f4d7bd7c343209b5e9"
    nonisolated static let downloadURL = URL(string: "https://github.com/typemeit/typemeit/releases/download/model-fluidaudio-diarizer-df2625ac/speaker-diarization-df2625ac.tar")!
    /// What the tar unpacks to, and what FluidAudio's `Repo.diarizer.folderName` resolves to.
    nonisolated static let folderName = "speaker-diarization"
    /// The files the offline pipeline loads, relative to `folderName`, and
    /// the revision marker FluidAudio checks before trusting them.
    nonisolated static let requiredFiles = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json", ".fluidaudio-revision"]
    /// For `transcription.diarizer`: the pipeline and the weights' revision.
    nonisolated static let pipelineName = "pyannote-community-1+wespeaker+vbx df2625ac"

    /// A `pipelineName` as a person reads it, its models without their
    /// versions or the revision: "pyannote + wespeaker + vbx".
    nonisolated static func label(of pipeline: String) -> String {
        let models = pipeline.split(separator: " ").first ?? Substring(pipeline)
        return models.split(separator: "+").map { $0.split(separator: "-").first.map(String.init) ?? String($0) }.joined(separator: " + ")
    }

    /// The directory FluidAudio is pointed at; the models sit in `folderName` under it.
    nonisolated static let directory = ModelStore.modelsDirectory.appendingPathComponent("diarizer", isDirectory: true)
    nonisolated static let modelFolder = directory.appendingPathComponent(folderName, isDirectory: true)

    enum State: Equatable, Sendable {
        case missing
        case downloading(received: Int64, total: Int64)
        case verifying
        case failed(String)
        case installed
    }

    private(set) var state: State
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    private override init() {
        state = DiarizerModelStore.isInstalled ? .installed : .missing
        super.init()
    }

    nonisolated static var isInstalled: Bool {
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent($0).path) }
    }

    func download() {
        guard task == nil, state != .installed else { return }
        state = .downloading(received: 0, total: DiarizerModelStore.expectedBytes)
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
            self.resumeData = nil
        } else {
            task = session.downloadTask(with: DiarizerModelStore.downloadURL)
        }
        task?.resume()
    }

    func cancel() {
        task?.cancel { [weak self] data in
            Task { @MainActor in
                self?.resumeData = data
                self?.task = nil
                self?.state = .missing
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.state = .downloading(received: totalBytesWritten, total: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : DiarizerModelStore.expectedBytes)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move out of the temporary location synchronously; it is deleted when this returns.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("typemeit-diarizer-\(UUID().uuidString)", isDirectory: true)
        let tar = staging.appendingPathComponent(DiarizerModelStore.fileName)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: tar)
        } catch {
            Task { @MainActor in self.fail("Could not save the download: \(error.localizedDescription)") }
            return
        }
        Task { @MainActor in
            self.state = .verifying
            let installed = await DiarizerModelStore.install(tar, staging: staging)
            switch installed {
            case .success:
                self.task = nil
                self.state = .installed
                Log.meetings.info("Speaker model installed")
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
        Task { @MainActor in
            self.resumeData = resume
            self.fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        task = nil
        state = .failed(message)
        Log.meetings.error("Speaker model download failed: \(message)")
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

    /// Hash-checks and untars in `staging`, then moves the model folder into
    /// place with one rename. Anything that fails leaves the models
    /// directory as it was and deletes the staging directory.
    private nonisolated static func install(_ tar: URL, staging: URL) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                guard try verify(tar) else { throw InstallError.checksum }
                let untar = Process()
                untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                untar.arguments = ["-xf", tar.path, "-C", staging.path]
                try untar.run()
                untar.waitUntilExit()
                guard untar.terminationStatus == 0 else { throw InstallError.untar(untar.terminationStatus) }
                let unpacked = staging.appendingPathComponent(folderName, isDirectory: true)
                guard requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: unpacked.appendingPathComponent($0).path) }) else { throw InstallError.incomplete }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: modelFolder)
                try FileManager.default.moveItem(at: unpacked, to: modelFolder)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
    }

    private nonisolated static func verify(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256
    }
}
