/// Generates all AppIcon.iconset PNG sizes (16…1024); build-app.sh then composes the icns
/// via iconutil. Usage: render-icon <output.iconset directory>
import Foundation
import HidiPiIcon

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("Usage: render-icon <output.iconset directory>\n".data(using: .utf8)!)
    exit(64)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

// The fixed manifest iconutil requires; the icon is an 18×18 square design, so
// non-square sizes (like 3276) do not apply.
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
    guard let data = IconDrawing.pngData(width: pixels, height: pixels) else {
        FileHandle.standardError.write("Render failed: \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: directory.appendingPathComponent(name))
}
print("iconset generated: \(directory.path)")
