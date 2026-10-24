// Turns on the System Extension capability for the apps that add the type me
// it camera, and makes and installs their provisioning profiles, through the
// App Store Connect API:
//
//   it.typeme.typemeit Developer ID         type me it, which adds the camera itself
//   it.typeme.typemeit.camera Developer ID  the camera's installer for dev builds (Camera/Host)
//   it.typeme.typemeit AppStore             made again: a capability change invalidates it
//
// Run once per account, and again when a certificate is renewed.
//
//   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=… swift Scripts/signing-profiles.swift
//
// The names are the PROVISIONING_PROFILE_SPECIFIERs in project.yml. The
// release workflow installs the first and last from the MAC_DEVELOPER_ID_PROFILE
// and MAC_APP_STORE_PROFILE secrets: each printed path, base64.

import CryptoKit
import Foundation

struct Profile {
    let bundleID: String
    let name: String
    let type: String
    /// Certificate types the profile may carry, newest kind first.
    let certificateTypes: [String]
    /// The bundle id's name, used when it is not registered yet.
    let appName: String
}

/// Certificates made since Apple's G2 intermediate carry the _G2 type.
let developerID = ["DEVELOPER_ID_APPLICATION_G2", "DEVELOPER_ID_APPLICATION"]
let profiles = [
    Profile(bundleID: "it.typeme.typemeit", name: "it.typeme.typemeit Developer ID", type: "MAC_APP_DIRECT",
            certificateTypes: developerID, appName: "type me it"),
    Profile(bundleID: "it.typeme.typemeit.camera", name: "it.typeme.typemeit.camera Developer ID", type: "MAC_APP_DIRECT",
            certificateTypes: developerID, appName: "type me it camera"),
    Profile(bundleID: "it.typeme.typemeit", name: "it.typeme.typemeit AppStore", type: "MAC_APP_STORE",
            certificateTypes: ["DISTRIBUTION"], appName: "type me it"),
]

let api = URL(string: "https://api.appstoreconnect.apple.com/v1/")!
/// App Store Connect refuses a token that lives longer than this.
let tokenSeconds = 20.0 * 60

let environment = ProcessInfo.processInfo.environment
guard let keyID = environment["ASC_KEY_ID"], let issuer = environment["ASC_ISSUER_ID"], let keyPath = environment["ASC_KEY_PATH"] else {
    print("set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH")
    exit(1)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let token: String = {
    let key = try! P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: keyPath, encoding: .utf8))
    let now = Date().timeIntervalSince1970
    let header = try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let claims = try! JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": Int(now), "exp": Int(now + tokenSeconds), "aud": "appstoreconnect-v1"])
    let unsigned = base64URL(header) + "." + base64URL(claims)
    let signature = try! key.signature(for: Data(unsigned.utf8)).rawRepresentation
    return unsigned + "." + base64URL(signature)
}()

func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> (status: Int, json: [String: Any]) {
    var request = URLRequest(url: URL(string: path, relativeTo: api)!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as! HTTPURLResponse).statusCode
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    if status >= 400 {
        let errors = (json["errors"] as? [[String: Any]] ?? []).map { "\($0["title"] ?? ""): \($0["detail"] ?? "")" }
        print("\(method) \(path): \(status) \(errors.joined(separator: "; "))")
    }
    return (status, json)
}

func items(_ json: [String: Any]) -> [[String: Any]] { json["data"] as? [[String: Any]] ?? [] }
func attribute(_ item: [String: Any], _ key: String) -> String? { (item["attributes"] as? [String: Any])?[key] as? String }

/// The keychain's Developer ID certificate's serial number, to pick the same one in the account.
func localDeveloperIDSerial() -> String? {
    let find = Process()
    find.executableURL = URL(fileURLWithPath: "/bin/sh")
    find.arguments = ["-c", "security find-certificate -c 'Developer ID Application' -p | openssl x509 -noout -serial"]
    let out = Pipe()
    find.standardOutput = out
    try? find.run()
    find.waitUntilExit()
    let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return line.split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
}

/// The bundle id's record, registered if it is not yet, with the System Extension capability on.
func bundleRecord(for profile: Profile) async throws -> String {
    let found = items(try await call("GET", "bundleIds?filter[identifier]=\(profile.bundleID)").json)
        .first { attribute($0, "identifier") == profile.bundleID }
    var record = found?["id"] as? String
    if record == nil {
        let created = try await call("POST", "bundleIds", ["data": ["type": "bundleIds", "attributes": [
            "identifier": profile.bundleID, "name": profile.appName, "platform": "MAC_OS"]]])
        record = (created.json["data"] as? [String: Any])?["id"] as? String
    }
    guard let record else { print("no bundle id \(profile.bundleID)"); exit(1) }
    // Posting it again, even when it is on, invalidates the bundle id's profiles made so far.
    let capabilities = items(try await call("GET", "bundleIds/\(record)/bundleIdCapabilities").json)
    if capabilities.contains(where: { attribute($0, "capabilityType") == "SYSTEM_EXTENSION_INSTALL" }) { return record }
    let capability = try await call("POST", "bundleIdCapabilities", ["data": [
        "type": "bundleIdCapabilities",
        "attributes": ["capabilityType": "SYSTEM_EXTENSION_INSTALL"],
        "relationships": ["bundleId": ["data": ["type": "bundleIds", "id": record]]],
    ]])
    guard capability.status < 400 else { exit(1) }
    return record
}

/// The certificates the old profile of this name carried, or else the
/// account's of the profile's types, preferring the one in this keychain.
func certificates(for profile: Profile, old: [[String: Any]]) async throws -> [String] {
    for oldProfile in old {
        guard let id = oldProfile["id"] as? String else { continue }
        let carried = items(try await call("GET", "profiles/\(id)/certificates").json).compactMap { $0["id"] as? String }
        if !carried.isEmpty { return carried }
    }
    let ofType = items(try await call("GET", "certificates?filter[certificateType]=\(profile.certificateTypes.joined(separator: ","))&limit=50").json)
    let serial = localDeveloperIDSerial()
    let mine = ofType.filter { attribute($0, "serialNumber")?.uppercased() == serial }
    return (mine.isEmpty ? ofType : mine).compactMap { $0["id"] as? String }
}

// Where Xcode looks for profiles.
let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

for profile in profiles {
    let bundle = try await bundleRecord(for: profile)
    // The API's name filter matches nothing, so every profile is listed and matched here.
    let old = items(try await call("GET", "profiles?limit=200").json).filter { attribute($0, "name") == profile.name }
    let carried = try await certificates(for: profile, old: old)
    guard !carried.isEmpty else { print("no \(profile.certificateTypes.joined(separator: " or ")) certificate in the account"); exit(1) }
    // Made again so it carries the capability.
    for oldProfile in old {
        if let id = oldProfile["id"] as? String { _ = try await call("DELETE", "profiles/\(id)") }
    }
    let made = try await call("POST", "profiles", ["data": [
        "type": "profiles",
        "attributes": ["name": profile.name, "profileType": profile.type],
        "relationships": [
            "bundleId": ["data": ["type": "bundleIds", "id": bundle]],
            "certificates": ["data": carried.map { ["type": "certificates", "id": $0] }],
        ],
    ]])
    guard let attributes = (made.json["data"] as? [String: Any])?["attributes"] as? [String: Any],
          let content = attributes["profileContent"] as? String, let uuid = attributes["uuid"] as? String,
          let data = Data(base64Encoded: content) else { exit(1) }
    let file = folder.appendingPathComponent("\(uuid).provisionprofile")
    try data.write(to: file)
    print("\(profile.name): \(file.path)")
}
