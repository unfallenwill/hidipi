/// Status-bar icon: a display outline plus a 2×2 pixel array, expressing HiDPI's doubled
/// pixel rendering. Geometry matches hidipi/scripts/render-status-icon.swift /
/// StatusIconTemplate.svg exactly, drawn in a flipped 18×18 coordinate system. The single
/// source shared by the status-bar icon and the app icns.
import AppKit

public enum IconDrawing {
    public static let points: CGFloat = 18

    /// Draws the template shape (black) in 18×18 logical coordinates in the current NSGraphicsContext.
    public static func draw() {
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let screen = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.75, width: 14.5, height: 10.5),
                                  xRadius: 1.5, yRadius: 1.5)
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
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 2, height: 2),
                             xRadius: 0.25, yRadius: 0.25).fill()
            }
        }
    }

    /// Renders a PNG at the given pixel size (scale = size / 18).
    public static func pngData(width: Int, height: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: CGFloat(width) / points, y: -CGFloat(height) / points)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    /// NSImage for the status bar: 18 pt logical size, 1x/2x/3x representations, template coloring.
    public static func statusItemIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points))
        for scale in [1, 2, 3] {
            let side = Int(points) * scale
            if let data = pngData(width: side, height: side),
               let rep = NSBitmapImageRep(data: data) {
                rep.size = NSSize(width: points, height: points)
                image.addRepresentation(rep)
            }
        }
        image.isTemplate = true
        return image
    }
}
