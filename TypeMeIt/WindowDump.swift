import AppKit
import QuartzCore

/// Dev builds' Dump Windows: each of the app's visible windows as its own
/// layers drew it, to a PNG, and its view and layer tree with every frame, to
/// text, both in `MeetingProbes.directory`. For a window that shows nothing
/// on screen: the tree says whether a view got no size, a non-finite one, or
/// drew somewhere else. Needs no screen recording permission, since it
/// renders the app's own layers.
@MainActor
enum WindowDump {
    static func write() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        var text: [String] = []
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            text.append("window \(i) \"\(window.title)\" \(describe(window.frame)) \(type(of: window))")
            guard let content = window.contentView else { continue }
            text.append("fitting size \(content.fittingSize)")
            views(content, depth: 1, into: &text)
            if let layer = content.layer {
                text.append("layers")
                layers(layer, depth: 1, into: &text)
                png(layer, size: content.bounds.size, scale: window.backingScaleFactor, to: "window-\(i)-\(stamp).png")
            }
        }
        let file = MeetingProbes.directory.appendingPathComponent("windows-\(stamp).txt")
        do {
            try FileManager.default.createDirectory(at: MeetingProbes.directory, withIntermediateDirectories: true)
            try text.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            DebugLog.write("Window dump: \(file.lastPathComponent)")
        } catch {
            DebugLog.write("Window dump: \(error.localizedDescription)")
        }
    }

    /// A tree deeper than this is SwiftUI's own plumbing all the way down.
    private static let maxDepth = 40

    private static func views(_ view: NSView, depth: Int, into text: inout [String]) {
        guard depth < maxDepth else { return }
        text.append(String(repeating: " ", count: depth) + "\(type(of: view)) \(describe(view.frame))\(view.isHidden ? " hidden" : "")\(view.alphaValue < 1 ? " alpha \(view.alphaValue)" : "")")
        for sub in view.subviews { views(sub, depth: depth + 1, into: &text) }
    }

    private static func layers(_ layer: CALayer, depth: Int, into text: inout [String]) {
        guard depth < maxDepth else { return }
        let contents = layer.contents == nil ? "" : " contents"
        text.append(String(repeating: " ", count: depth) + "\(type(of: layer)) \(describe(layer.frame))\(layer.isHidden ? " hidden" : "")\(layer.opacity < 1 ? " opacity \(layer.opacity)" : "")\(contents)")
        for sub in layer.sublayers ?? [] { layers(sub, depth: depth + 1, into: &text) }
    }

    /// A frame, flagged when it could not be drawn.
    private static func describe(_ r: CGRect) -> String {
        let values = [r.origin.x, r.origin.y, r.width, r.height]
        let flag = values.contains { !$0.isFinite } ? " NON-FINITE" : (r.width == 0 || r.height == 0 ? " EMPTY" : "")
        return "(\(Int(r.origin.x.isFinite ? r.origin.x : 0)),\(Int(r.origin.y.isFinite ? r.origin.y : 0)) \(r.width.isFinite ? Int(r.width) : -1)x\(r.height.isFinite ? Int(r.height) : -1))\(flag)"
    }

    private static func png(_ layer: CALayer, size: CGSize, scale: CGFloat, to name: String) {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: MeetingProbes.directory.appendingPathComponent(name))
    }
}
