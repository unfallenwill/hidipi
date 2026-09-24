/// CGDisplayCreateUUIDFromDisplayID 的 dlsym shim。
/// macOS 27 起该符号不再由 CoreGraphics 导出，需回退 SkyLight（与 macos.py 相同路径）。
import Foundation
import HidiPiCore
import CoreGraphics

enum DisplayUUID {
    private typealias CreateUUIDFn = @convention(c) (CGDirectDisplayID) -> CFUUID?

    private static let fn: CreateUUIDFn? = {
        let candidates = [
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        ]
        for path in candidates {
            guard let handle = dlopen(path, RTLD_LAZY),
                  let symbol = dlsym(handle, "CGDisplayCreateUUIDFromDisplayID") else { continue }
            return unsafeBitCast(symbol, to: CreateUUIDFn.self)
        }
        return nil
    }()

    /// macos.identity：CFUUIDCreateString 的大写规范形式，跨重启稳定。
    static func string(for display: CGDirectDisplayID) throws -> String {
        guard let fn, let uuid = fn(display),
              let string = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String? else {
            throw HiDPIError("无法取得显示器 \(display) 的 UUID；不能可靠备份。")
        }
        return string
    }
}
