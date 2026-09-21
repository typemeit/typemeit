import Foundation

/// Where a sealed drop is left and collected. The worker behind this is in
/// `worker.js`; `TYPEMEIT_SHARE_HOST` points a debug build at one running
/// somewhere else.
enum ShareDrop {
    static var host: String {
        let named = ProcessInfo.processInfo.environment["TYPEMEIT_SHARE_HOST"]
        return (named?.isEmpty == false ? named : nil) ?? "typeme.it"
    }

    /// Notes are text, and half a megabyte of it is more than anyone hands
    /// over in one go. The worker turns away more than this too.
    static let maxBytes = 512 * 1024

    enum Failure: Error, Equatable {
        case tooMuch
        case unreachable(String)
        /// Nothing under that name: never left, already collected, or the ten
        /// minutes are up.
        case gone
    }

    private static func url(_ name: String) -> URL? {
        URL(string: "https://\(host)/share/note/\(name)")
    }

    /// Leaves the sealed bytes under `name`.
    static func put(_ blob: Data, name: String) async throws {
        guard blob.count <= maxBytes else { throw Failure.tooMuch }
        guard let url = url(name) else { throw Failure.unreachable(host) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: blob)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 201 || code == 200 else { throw Failure.unreachable("\(host) said \(code)") }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
    }

    /// Collects what is under `name`, which the server then forgets. A drop
    /// is good for one collection.
    static func take(name: String) async throws -> Data {
        guard let url = url(name) else { throw Failure.unreachable(host) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw Failure.gone }
            guard code == 200 else { throw Failure.unreachable("\(host) said \(code)") }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
    }
}
