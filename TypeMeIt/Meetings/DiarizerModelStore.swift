import CryptoKit
import FluidAudio
import Foundation
import Observation

/// Downloads and locates the speaker models: one tar of Nemotron 3
/// Diarization's files and the offline pyannote pipeline's, hash-pinned,
/// from typeme.it's release bucket (docs/meetings.md 8.2). Modelled on `ModelStore`. The download lands in
/// a temporary directory, is hash-checked and untarred there, and moved
/// into place with one rename, so an interrupted download leaves nothing
/// behind. `make diarizer-model-sums` prints the constants.
@MainActor
@Observable
final class DiarizerModelStore: NSObject, URLSessionDownloadDelegate {
    static let shared = DiarizerModelStore()

    nonisolated static let fileName = "speaker-models-df2625ac-25a90f97.tar"
    nonisolated static let expectedBytes: Int64 = 220_815_360
    nonisolated static let sha256 = "b57b9e901c7364e7ab5313e75a683a8d660e183cb894387f6a611599253b2f32"
    nonisolated static let downloadURL = URL(string: "https://typeme.it/models/\(fileName)")!
    /// The offline pipeline's folder in the tar, and what FluidAudio's `Repo.diarizer.folderName` resolves to.
    nonisolated static let folderName = "speaker-diarization"
    /// Nemotron's folder in the tar, which `Nemotron3Models.load(config:directory:)` reads.
    nonisolated static let nemotronFolderName = "nemotron-3-diarization"
    /// Every file the two models load, relative to `directory`, and the
    /// revision marker FluidAudio checks before trusting the offline pipeline's.
    nonisolated static let requiredFiles = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json", ".fluidaudio-revision"]
        .map { "\(folderName)/\($0)" }
        + ["\(nemotronFolderName)/\(Diarizer.turnConfig.modelFileName)", "\(nemotronFolderName)/\(ModelNames.Nemotron3.silenceEmbeddingFile)"]
    /// For `transcription.diarizer`: the models and the weights' revisions.
    nonisolated static let pipelineName = "nemotron-3-diarization+wespeaker df2625ac-25a90f97"

    /// A `pipelineName` as a person reads it, its models without their
    /// versions or the revision: "pyannote + wespeaker + vbx".
    nonisolated static func label(of pipeline: String) -> String {
        let models = pipeline.split(separator: " ").first ?? Substring(pipeline)
        return models.split(separator: "+").map { $0.split(separator: "-").first.map(String.init) ?? String($0) }.joined(separator: " + ")
    }

    /// The directory FluidAudio is pointed at; the models sit in `folderName` under it.
    nonisolated static let directory = ModelStore.modelsDirectory.appendingPathComponent("diarizer", isDirectory: true)
    nonisolated static let nemotronFolder = directory.appendingPathComponent(nemotronFolderName, isDirectory: true)

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
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
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

    /// Hash-checks and untars in `staging`, then moves each model folder
    /// into place with one rename. Anything that fails before the moves
    /// leaves the models directory as it was and deletes the staging directory.
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
                guard requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: staging.appendingPathComponent($0).path) }) else { throw InstallError.incomplete }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for folder in [folderName, nemotronFolderName] {
                    let installed = directory.appendingPathComponent(folder, isDirectory: true)
                    try? FileManager.default.removeItem(at: installed)
                    try FileManager.default.moveItem(at: staging.appendingPathComponent(folder, isDirectory: true), to: installed)
                }
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
