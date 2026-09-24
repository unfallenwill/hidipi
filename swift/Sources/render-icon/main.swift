/// 生成 AppIcon.iconset 全尺寸 PNG（16…1024），随后由 build-app.sh 调 iconutil 合成 icns。
/// 用法：render-icon <输出.iconset 目录>
import Foundation
import HidiPiIcon

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("用法：render-icon <输出.iconset 目录>\n".data(using: .utf8)!)
    exit(64)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

// iconutil 要求的固定清单；图标为 18×18 方形设计，非正交尺寸（如 3276）不适用。
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
    guard let data = IconDrawing.pngData(width: pixels, height: pixels) else {
        FileHandle.standardError.write("渲染失败：\(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: directory.appendingPathComponent(name))
}
print("iconset 已生成：\(directory.path)")
