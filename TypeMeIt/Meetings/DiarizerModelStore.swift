import FluidAudio
import Foundation

/// Downloads and locates the speaker models: one tar of Nemotron 3
/// Diarization's files and the offline pyannote pipeline's, hash-pinned,
/// from typeme.it's release bucket (docs/meetings.md 8.2), downloaded the
/// way `ModelStore`'s is. `make diarizer-model-sums` prints the constants.
final class DiarizerModelStore: PinnedDownload {
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

    nonisolated static let spec = Spec(
        name: "speaker models", url: downloadURL, expectedBytes: expectedBytes, sha256: sha256, workDirectory: ModelStore.modelsDirectory,
        requiredFiles: requiredFiles,
        folders: [.init(name: folderName, destination: directory.appendingPathComponent(folderName, isDirectory: true)),
                  .init(name: nemotronFolderName, destination: nemotronFolder)],
        log: Log.meetings)

    private init() {
        super.init(spec: DiarizerModelStore.spec, installed: DiarizerModelStore.isInstalled)
    }

    nonisolated static var isInstalled: Bool {
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
}
