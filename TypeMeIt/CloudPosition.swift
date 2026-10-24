import Foundation

/// Where on the screen the recording cloud sits: the bottom middle, the top
/// middle, or against the left or right edge halfway up.
enum CloudPosition: String, Codable, CaseIterable, Sendable {
    case left, top, centre, right

    var label: String {
        switch self {
        case .left: "left"
        case .top: "top"
        case .centre: "bottom"
        case .right: "right"
        }
    }
}
