// Renders the Chromeless app icon: viewfinder corners on a dark squircle.
// Usage: swift tools/make-icon.swift <output.iconset>

import Cocoa

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(px) / 1024.0)
    scale.concat()

    // Dark squircle canvas (standard macOS icon grid: 824pt centered on 1024).
    let squircle = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                                xRadius: 186, yRadius: 186)
    NSGradient(starting: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.14, alpha: 1),
               ending: NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.04, alpha: 1))!
        .draw(in: squircle, angle: -90)
    NSColor.white.withAlphaComponent(0.07).setStroke()
    squircle.lineWidth = 6
    squircle.stroke()

    // Viewfinder corners — a frame with no chrome.
    let box = NSRect(x: 302, y: 302, width: 420, height: 420)
    let arm: CGFloat = 126
    let p = NSBezierPath()
    p.lineWidth = 46
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    // top-left
    p.move(to: NSPoint(x: box.minX, y: box.maxY - arm))
    p.line(to: NSPoint(x: box.minX, y: box.maxY))
    p.line(to: NSPoint(x: box.minX + arm, y: box.maxY))
    // top-right
    p.move(to: NSPoint(x: box.maxX - arm, y: box.maxY))
    p.line(to: NSPoint(x: box.maxX, y: box.maxY))
    p.line(to: NSPoint(x: box.maxX, y: box.maxY - arm))
    // bottom-right
    p.move(to: NSPoint(x: box.maxX, y: box.minY + arm))
    p.line(to: NSPoint(x: box.maxX, y: box.minY))
    p.line(to: NSPoint(x: box.maxX - arm, y: box.minY))
    // bottom-left
    p.move(to: NSPoint(x: box.minX + arm, y: box.minY))
    p.line(to: NSPoint(x: box.minX, y: box.minY))
    p.line(to: NSPoint(x: box.minX, y: box.minY + arm))
    NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
    p.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    try render(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("iconset written to \(outDir)")
