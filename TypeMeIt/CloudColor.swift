import AppKit

/// The recording cloud's colour when it is not dynamic: black, white, or
/// one of seven hues.
enum CloudColor: String, Codable, CaseIterable, Sendable {
    case black, white, coral, amber, lemon, mint, sky, lavender, rose

    /// The two a dynamic cloud chooses between.
    static let neutrals: [CloudColor] = [.black, .white]
    static var hues: [CloudColor] { allCases.filter { !neutrals.contains($0) } }

    var label: String { rawValue }

    var color: NSColor {
        switch self {
        case .black: NSColor(white: 0.25, alpha: 1)
        case .white: NSColor(white: 1, alpha: 1)
        case .coral: NSColor(srgbRed: 0.98, green: 0.49, blue: 0.40, alpha: 1)
        case .amber: NSColor(srgbRed: 0.98, green: 0.69, blue: 0.29, alpha: 1)
        case .lemon: NSColor(srgbRed: 0.96, green: 0.86, blue: 0.36, alpha: 1)
        case .mint: NSColor(srgbRed: 0.45, green: 0.85, blue: 0.66, alpha: 1)
        case .sky: NSColor(srgbRed: 0.42, green: 0.70, blue: 0.96, alpha: 1)
        case .lavender: NSColor(srgbRed: 0.66, green: 0.60, blue: 0.95, alpha: 1)
        case .rose: NSColor(srgbRed: 0.95, green: 0.58, blue: 0.78, alpha: 1)
        }
    }
}
