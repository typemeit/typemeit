import Foundation

/// The models Claude Code offers this account, read from the CLI itself: it
/// answers the `initialize` request the Agent SDK sends over
/// `--input-format stream-json` with them. `supportsAutoMode` marks those that
/// run in auto mode; any other would ask for approval, with nobody there to give it.
enum ClaudeModels {
    struct Model: Decodable, Equatable, Sendable {
        let value: String
        let displayName: String
        let description: String
        let supportsAutoMode: Bool?
    }

    static let timeoutSeconds = 20.0
    private static let request = #"{"request_id":"models","type":"control_request","request":{"subtype":"initialize"}}"#

    static func load() async -> [Model] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: read()) }
        }
    }

    private static func read() -> [Model] {
        guard let executable = ClaudeRun.executable else { return [] }
        let process = Process()
        process.executableURL = executable
        // Bare: no hooks, plugins or MCP servers are started just to list models.
        process.arguments = ["-p", "--bare", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        process.environment = ClaudeRun.environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        stdin.fileHandleForWriting.write(Data((request + "\n").utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { if process.isRunning { process.terminate() } }
        defer {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        var pending = Data()
        while true {
            let read = stdout.fileHandleForReading.availableData
            guard !read.isEmpty else { break }
            pending.append(read)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let models = models(in: Data(line)) { return models }
            }
        }
        DebugLog.write("Claude models: the CLI gave no model list")
        return []
    }

    /// The models in an `initialize` control response line, or nil for any other line.
    static func models(in line: Data) -> [Model]? {
        struct Line: Decodable {
            struct Outer: Decodable {
                struct Inner: Decodable { let models: [Model] }
                let response: Inner?
            }
            let type: String
            let response: Outer?
        }
        guard let decoded = try? JSONDecoder().decode(Line.self, from: line), decoded.type == "control_response" else { return nil }
        return decoded.response?.response?.models
    }
}
