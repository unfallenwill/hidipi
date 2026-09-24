/// CoreGraphics 基础访问：移植 macos.py 的 ids/info/modes/check。
import Foundation
import HidiPiCore
import CoreGraphics
import AppKit

enum DisplayIO {
    /// macos.check：CGError → 中文错误。
    static func check(_ code: CGError, _ operation: String) throws {
        if code != .success {
            throw HiDPIError("\(operation) 失败，CoreGraphics 错误码 \(code.rawValue)")
        }
    }

    /// CGGetOnlineDisplayList（上限 128，同 Python）。
    static func onlineIDs() throws -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 128)
        var count: UInt32 = 0
        try check(CGGetOnlineDisplayList(128, &ids, &count), "读取显示器")
        return Array(ids.prefix(Int(count)))
    }

    /// macos.info：CGDisplayMode → ModeInfo（Swift 导入为属性访问）。
    static func info(_ mode: CGDisplayMode) -> ModeInfo {
        ModeInfo(width: mode.width, height: mode.height,
                 pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                 hz: mode.refreshRate,
                 modeID: UInt32(bitPattern: mode.ioDisplayModeID),
                 flags: mode.ioFlags,
                 usable: mode.isUsableForDesktopGUI())
    }

    /// 当前模式。macos.current 的完整移植：虚拟屏（0xF0F0）在 CG 无模式时
    /// 回退 NSScreen（启动期 CG 可能只发布 NSScreen 数据；hz 未知记 0，
    /// VirtualDisplayController.modeMatches 对 hz=0 容差正是为此）。
    /// CGDisplayCopy* 遵循 +1 约定，由 ARC 释放。
    static func currentMode(_ display: CGDirectDisplayID) -> ModeInfo? {
        if let mode = CGDisplayCopyDisplayMode(display) { return info(mode) }
        guard CGDisplayVendorNumber(display) == VirtualBridge.vendorID else { return nil }
        return screenMode(display)
    }

    /// macos.screen_mode：从 NSScreen 的 deviceDescription 读回退模式。
    private static func screenMode(_ display: CGDirectDisplayID) -> ModeInfo? {
        for screen in NSScreen.screens ?? [] {
            guard let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  number == display else { continue }
            let scale = screen.backingScaleFactor
            let width = Int(screen.frame.width.rounded())
            let height = Int(screen.frame.height.rounded())
            guard width > 0, height > 0 else { continue }
            return ModeInfo(width: width, height: height,
                            pixelWidth: Int((CGFloat(width) * scale).rounded()),
                            pixelHeight: Int((CGFloat(height) * scale).rounded()),
                            hz: 0, usable: true)
        }
        return nil
    }

    /// macos.modes：带 kCGDisplayShowDuplicateLowResolutionModes 的完整模式列表。
    /// CFArray → [CGDisplayMode] 桥接会逐个保留引用。
    static func allModes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let array = CGDisplayCopyAllDisplayModes(display, options) else { return [] }
        return array as? [CGDisplayMode] ?? []
    }
}
