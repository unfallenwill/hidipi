/// 状态栏图标：显示器轮廓 + 2×2 像素阵列，表达 HiDPI 双倍像素渲染。
/// 几何坐标与 hidipi/scripts/render-status-icon.swift / StatusIconTemplate.svg 逐字一致，
/// 在翻转的 18×18 坐标系中绘制。状态栏图标与 App icns 共用此唯一来源。
import AppKit

public enum IconDrawing {
    public static let points: CGFloat = 18

    /// 在当前 NSGraphicsContext 中按 18×18 逻辑坐标绘制模板图形（黑色）。
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

    /// 以指定像素尺寸渲染 PNG（scale = size / 18）。
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

    /// 状态栏用 NSImage：18 pt 逻辑尺寸，1x/2x/3x 表示，模板着色。
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
