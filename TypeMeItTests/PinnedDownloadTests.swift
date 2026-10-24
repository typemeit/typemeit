import CryptoKit
import Foundation
import OSLog
import Synchronization
import Testing
@testable import TypeMeIt

/// Answers each request the download under test makes with the next queued reply.
private final class QueuedReplies: URLProtocol {
    enum Reply: Sendable {
        case body(status: Int, Data)
        case connectionLost
    }

    static let queue = Mutex<[Reply]>([])
    static let requests = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        let reply = Self.queue.withLock { $0.isEmpty ? Reply.connectionLost : $0.removeFirst() }
        switch reply {
        case .body(let status, let bytes):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": "\(bytes.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        case .connectionLost:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
    }
}

/// A tar holding `models/weights.bin`, and a download of it into a fresh folder.
@MainActor
private struct Fixture {
    let root: URL
    let tar: Data
    let download: PinnedDownload

    var installedFile: URL { root.appendingPathComponent("installed/models/weights.bin") }
    var work: URL { root.appendingPathComponent("work", isDirectory: true) }

    init(replies: (Data) -> [QueuedReplies.Reply]) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.root = root
        let pack = root.appendingPathComponent("pack/models", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: pack.appendingPathComponent("weights.bin"))
        let tarURL = root.appendingPathComponent("models.tar")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        make.arguments = ["-cf", tarURL.path, "-C", pack.deletingLastPathComponent().path, "models"]
        try make.run()
        make.waitUntilExit()
        let tar = try Data(contentsOf: tarURL)
        self.tar = tar

        QueuedReplies.queue.withLock { $0 = replies(tar) }
        QueuedReplies.requests.withLock { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueuedReplies.self]
        let spec = PinnedDownload.Spec(
            name: "test model", url: URL(string: "https://typeme.it/models/models.tar")!,
            expectedBytes: Int64(tar.count), sha256: SHA256.hash(data: tar).map { String(format: "%02x", $0) }.joined(),
            workDirectory: root.appendingPathComponent("work", isDirectory: true),
            requiredFiles: ["models/weights.bin"],
            folders: [.init(name: "models", destination: root.appendingPathComponent("installed/models", isDirectory: true))],
            log: Logger(subsystem: Log.subsystem, category: "tests"))
        download = PinnedDownload(spec: spec, installed: false, configuration: configuration, retryDelay: .zero)
    }

    /// Starts the download and waits until it is installed or has failed.
    func run() async -> PinnedDownload.State {
        download.download()
        for _ in 0..<500 {
            switch download.state {
            case .installed, .failed: return download.state
            default: try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return download.state
    }
}

@MainActor
@Suite(.serialized)
struct PinnedDownloadTests {
    @Test func aVerifiedTarIsInstalledAndLeavesNothingBehind() async throws {
        let fixture = try Fixture { tar in [.body(status: 200, tar)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(await fixture.run() == .installed)
        #expect(FileManager.default.fileExists(atPath: fixture.installedFile.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.work.path) == [])
    }

    @Test func aTarThatFailsItsChecksumIsNotInstalled() async throws {
        let fixture = try Fixture { _ in [.body(status: 200, Data("not the tar".utf8))] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(await fixture.run() == .failed(PinnedDownload.InstallError.checksum.errorDescription!))
        #expect(!FileManager.default.fileExists(atPath: fixture.installedFile.path))
    }

    @Test func anErrorPageIsFetchedAgainNotCheckedAsTheTar() async throws {
        let fixture = try Fixture { tar in [.body(status: 404, Data("not found".utf8)), .body(status: 200, tar)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(await fixture.run() == .installed)
    }

    @Test func aDroppedConnectionIsPickedUpAgain() async throws {
        let fixture = try Fixture { tar in [.connectionLost, .body(status: 200, tar)] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(await fixture.run() == .installed)
    }

    @Test func aConnectionThatKeepsDroppingFailsAfterTheRetries() async throws {
        let fixture = try Fixture { _ in [] }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(await fixture.run() == .failed(PinnedDownload.stoppedMessage))
        #expect(QueuedReplies.requests.withLock { $0 } == PinnedDownload.maxRetries + 1)
    }
}
