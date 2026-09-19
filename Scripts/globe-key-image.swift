#!/usr/bin/env swift
// Builds the onboarding image for the 🌐 key step from screenshots in
// design/onboarding: the Keyboard settings card with the "Press 🌐 key to"
// row outlined, and the popup menu with Do Nothing ticked beneath it. One
// light and one dark variant go into the fn-key-setting image set.
//
//   swift Scripts/globe-key-image.swift
//
// The crop rectangles are pixel positions in the source screenshots; retake
// a screenshot and they need measuring again.
import AppKit

struct Variant {
    let name: String
    let window: String        // screenshot with the Keyboard pane
    let menu: String          // screenshot of the open popup, transparent margin
    let card: CGRect          // the settings card, in window pixels
    let fnRow: ClosedRange<CGFloat>  // the row's top and bottom, in card pixels from the top
    let scale: CGFloat        // the window screenshot's pixels per point
    let stroke: NSColor       // the outline; ink on light, paper on dark
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let src = root.appendingPathComponent("design/onboarding")
let out = root.appendingPathComponent("TypeMeIt/Resources/Assets.xcassets/fn-key-setting.imageset")

let variants = [
    // Both window captures were taken at the same size, so they share a crop.
    Variant(name: "dark", window: "keyboard-dark.png", menu: "globe-menu-dark.png",
            card: CGRect(x: 582, y: 351, width: 933, height: 530), fnRow: 227...297, scale: 2, stroke: .white),
    Variant(name: "light", window: "keyboard-light.png", menu: "globe-menu-light.png",
            card: CGRect(x: 582, y: 351, width: 933, height: 530), fnRow: 227...297, scale: 2, stroke: .black),
]

/// Output width in 2x pixels; every variant is scaled to it.
let width: CGFloat = 955
let strokeWidth: CGFloat = 10
let menuOverhang: CGFloat = 70  // room below the card for the menu

func bitmap(_ name: String) -> NSBitmapImageRep {
    NSImage(contentsOf: src.appendingPathComponent(name))!.representations[0] as! NSBitmapImageRep
}

func render(_ v: Variant) -> NSBitmapImageRep {
    let window = bitmap(v.window), menu = bitmap(v.menu)
    let k = width / v.card.width
    let h = v.card.height * k
    let W = Int(width), H = Int(h + menuOverhang)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.interpolationQuality = .high
    // The pane background outside the card, sampled just above it.
    let bg = window.colorAt(x: Int(v.card.midX), y: Int(v.card.minY) - 4)!
    bg.setFill(); NSBezierPath.fill(CGRect(x: 0, y: 0, width: W, height: H))
    // CGImage cropping counts from the top; the context draws from the bottom.
    let card = window.cgImage!.cropping(to: v.card)!
    ctx.cgContext.draw(card, in: CGRect(x: 0, y: menuOverhang, width: width, height: h))
    let top = v.fnRow.lowerBound * k, bottom = v.fnRow.upperBound * k
    // Framed a little outside the row so the stroke sits in the gutter, not on the controls.
    let pad: CGFloat = 12
    // Inset by half the stroke so the whole line lands inside the image.
    let inset = strokeWidth / 2
    let row = CGRect(x: inset, y: menuOverhang + h - bottom - pad, width: width - 2 * inset, height: bottom - top + 2 * pad)
    let outline = NSBezierPath(rect: row)
    v.stroke.setStroke(); outline.lineWidth = strokeWidth; outline.stroke()
    let mw = CGFloat(menu.pixelsWide), mh = CGFloat(menu.pixelsHigh)
    ctx.cgContext.draw(menu.cgImage!, in: CGRect(x: width - mw - 10, y: menuOverhang + h - bottom - mh + 6, width: mw, height: mh))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func halve(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
    let w = rep.pixelsWide / 2, h = rep.pixelsHigh / 2
    let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: small)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.interpolationQuality = .high
    ctx.cgContext.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return small
}

try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for v in variants {
    let rep = render(v)
    write(rep, "fn-key-\(v.name)@2x.png")
    write(halve(rep), "fn-key-\(v.name).png")
    for (scale, suffix) in [("1x", ""), ("2x", "@2x")] {
        var entry = ["filename": "fn-key-\(v.name)\(suffix).png", "idiom": "universal", "scale": scale]
        if v.name == "dark" { entry["appearance"] = "dark" }
        images.append(entry)
    }
}
// Xcode wants the light entry without an appearances key and the dark one with luminosity=dark.
let contents: [String: Any] = [
    "images": images.map { e -> [String: Any] in
        var d: [String: Any] = ["filename": e["filename"]!, "idiom": e["idiom"]!, "scale": e["scale"]!]
        if e["appearance"] == "dark" { d["appearances"] = [["appearance": "luminosity", "value": "dark"]] }
        return d
    },
    "info": ["author": "xcode", "version": 1],
]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(variants.count) variants to \(out.path)")
