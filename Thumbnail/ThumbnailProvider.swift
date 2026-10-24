import AppKit
import QuickLookThumbnailing

// Finder's icon for a .tmi file: a page with the app icon on it. Without
// this, Finder draws the file's Markdown as a text thumbnail, because the
// type conforms to public.plain-text.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let side = min(request.maximumSize.width, request.maximumSize.height)
        // A sheet of A4 paper, scaled to fit the square Finder asks for.
        let pageSize = CGSize(width: side / 2.0.squareRoot(), height: side)
        let icon = Bundle(for: ThumbnailProvider.self).image(forResource: "AppIcon")
        handler(QLThumbnailReply(contextSize: pageSize) { () -> Bool in
            drawPage(size: pageSize, icon: icon)
            return true
        }, nil)
    }
}

private func drawPage(size: CGSize, icon: NSImage?) {
    let fold = size.width * 0.25
    let page = NSBezierPath()
    page.move(to: .zero)
    page.line(to: CGPoint(x: size.width, y: 0))
    page.line(to: CGPoint(x: size.width, y: size.height - fold))
    page.line(to: CGPoint(x: size.width - fold, y: size.height))
    page.line(to: CGPoint(x: 0, y: size.height))
    page.close()
    NSColor.white.setFill()
    page.fill()
    NSColor(white: 0, alpha: 0.15).setStroke()
    page.lineWidth = max(1, size.width / 128)
    page.stroke()

    let corner = NSBezierPath()
    corner.move(to: CGPoint(x: size.width - fold, y: size.height))
    corner.line(to: CGPoint(x: size.width - fold, y: size.height - fold))
    corner.line(to: CGPoint(x: size.width, y: size.height - fold))
    corner.close()
    NSColor(white: 0.9, alpha: 1).setFill()
    corner.fill()
    corner.lineWidth = page.lineWidth
    corner.stroke()

    guard let icon else { return }
    let iconSide = size.width * 0.7
    icon.draw(in: CGRect(
        x: (size.width - iconSide) / 2,
        y: (size.height - iconSide) / 2,
        width: iconSide,
        height: iconSide
    ))
}
