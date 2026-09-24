import AppKit
import Testing
@testable import HidiPiIcon

@Test func pngDataRendersEveryIconsetSize() {
    for pixels in [16, 32, 64, 128, 256, 512, 1024] {
        #expect(IconDrawing.pngData(width: pixels, height: pixels) != nil,
                "render failed at \(pixels)px")
    }
    #expect(IconDrawing.pngData(width: 18, height: 18) != nil)   // the design's own size
}

@Test func statusItemIconIsTemplateWithAllScales() {
    let image = IconDrawing.statusItemIcon()
    #expect(image.isTemplate)
    #expect(image.representations.count == 3)   // 1x / 2x / 3x
    #expect(image.size == NSSize(width: 18, height: 18))
}
