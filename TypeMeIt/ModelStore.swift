import FluidAudio
import Foundation

/// Downloads and locates the one speech model the app uses: Parakeet Ultra's
/// Core ML files in one hash-pinned tar from typeme.it's release bucket,
/// untarred to `directory` and loaded from there by `Transcriber`. A new model
/// is a new `version` and tar; the upgrade panel and the onboarding step read
/// the name, the reason and the size from here. `make asr-model-sums` prints
/// the constants.
final class ModelStore: PinnedDownload {
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

    nonisolated static let spec = Spec(
        name: displayName, url: downloadURL, expectedBytes: expectedBytes, sha256: sha256, workDirectory: modelsDirectory,
        requiredFiles: requiredFiles.map { "\(version)/\($0)" }, folders: [.init(name: version, destination: directory)], log: Log.model)

    private init() {
        try? FileManager.default.createDirectory(at: ModelStore.modelsDirectory, withIntermediateDirectories: true)
        super.init(spec: ModelStore.spec, installed: ModelStore.isInstalled)
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

    override func didInstall() {
        Settings.shared.speechModelVersion = ModelStore.version
        Task { await Transcriber.shared.preload() }
    }
}
