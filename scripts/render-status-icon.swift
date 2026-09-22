// Run from the repository root:
// swift -module-cache-path /tmp/hidipi-swift-cache scripts/render-status-icon.swift
import AppKit

let assets = URL(fileURLWithPath: "src/hidipi/assets", isDirectory: true)
let docs = URL(fileURLWithPath: "docs", isDirectory: true)
try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

// Coordinates match StatusIconTemplate.svg; draw in a flipped context.
func drawIcon(_ color: NSColor) {
    color.setStroke()
    color.setFill()
    let screen = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.75, width: 14.5, height: 10.5), xRadius: 1.5, yRadius: 1.5)
    screen.lineWidth = 1.5
    screen.stroke()
    let stand = NSBezierPath()
    stand.lineWidth = 1.5
    stand.lineCapStyle = .round
    stand.move(to: NSPoint(x: 9, y: 13.5))
    stand.line(to: NSPoint(x: 9, y: 16.25))
    stand.move(to: NSPoint(x: 6, y: 16.25))
    stand.line(to: NSPoint(x: 12, y: 16.25))
    stand.stroke()
    for x in [6.0, 10.0] {
        for y in [5.0, 9.0] {
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 2, height: 2), xRadius: 0.25, yRadius: 0.25).fill()
        }
    }
}

func png(width: Int, height: Int, scale: Int, to url: URL, draw: () -> Void) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.translateBy(x: 0, y: CGFloat(height * scale))
    context.cgContext.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

for scale in [1, 2, 3] {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    try png(width: 18, height: 18, scale: scale,
        to: assets.appendingPathComponent("StatusIconTemplate\(suffix).png")) { drawIcon(.black) }
}

try png(width: 640, height: 240, scale: 2, to: docs.appendingPathComponent("status-icon-preview.png")) {
    for (index, background, foreground) in [(0, NSColor(white: 0.96, alpha: 1), NSColor.black),
                                            (1, NSColor(white: 0.12, alpha: 1), NSColor.white)] {
        let offset = CGFloat(index * 320)
        background.setFill()
        NSRect(x: offset, y: 0, width: 320, height: 240).fill()
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: offset + 115, yBy: 28)
        transform.scale(by: 5)
        transform.concat()
        drawIcon(foreground)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        let small = NSAffineTransform()
        small.translateX(by: offset + 151, yBy: 157)
        small.concat()
        drawIcon(foreground)
        NSGraphicsContext.restoreGraphicsState()
        let label = "hidipi  /  18 pt" as NSString
        // NSString text drawing needs a context explicitly marked as flipped.
        let textContext = NSGraphicsContext(cgContext: NSGraphicsContext.current!.cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = textContext
        label.draw(at: NSPoint(x: offset + 111, y: 198), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: foreground.withAlphaComponent(0.65)
        ])
        NSGraphicsContext.restoreGraphicsState()
    }
}
