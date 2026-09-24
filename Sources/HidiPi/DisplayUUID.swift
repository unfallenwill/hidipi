/// dlsym shim for CGDisplayCreateUUIDFromDisplayID.
/// Since macOS 27 the symbol is no longer exported by CoreGraphics; fall back to SkyLight
/// (the same path as macos.py).
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

    /// macos.identity: CFUUIDCreateString's canonical uppercase form, stable across reboots.
    static func string(for display: CGDirectDisplayID) throws -> String {
        guard let fn, let uuid = fn(display),
              let string = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String? else {
            throw HiDPIError("Cannot obtain a UUID for display \(display); no reliable snapshot is possible.")
        }
        return string
    }
}
