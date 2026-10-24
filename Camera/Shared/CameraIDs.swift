import CoreMediaIO
import Foundation

/// What the camera extension and the app that feeds it agree on.
enum CameraIDs {
    /// The camera's name in a meeting app's camera menu.
    static let name = "type me it"
    static let manufacturer = "type me it"
    static let extensionID = "it.typeme.typemeit.camera.extension"
    /// The device's id, which Core Media I/O gives apps as its unique id.
    static let deviceID = UUID(uuidString: "D5744097-E5E9-4FFC-AE03-55B4A87BBB88")!
    static let sourceStreamID = UUID(uuidString: "619A0D7A-84DC-4B1B-B66D-CAEF83D1700A")!
    static let sinkStreamID = UUID(uuidString: "C196D96D-E905-4FF9-A390-F4CFC489D61D")!

    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let framesPerSecond: Int32 = 30

    /// A custom property of the source stream: how many apps are reading
    /// it, as a string, so the app runs the real camera only while a
    /// meeting shows this one. Core Media I/O names custom properties
    /// `4cc_<selector>_<scope>_<element>`.
    static let watchersProperty = "4cc_tmiw_glob_0000"
    static let watchersSelector: CMIOObjectPropertySelector = "tmiw".utf8.reduce(0) { $0 << 8 | CMIOObjectPropertySelector($1) }
}
