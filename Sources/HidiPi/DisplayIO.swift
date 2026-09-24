/// CoreGraphics basics: port of macos.py's ids/info/modes/check.
import Foundation
import HidiPiCore
import CoreGraphics
import AppKit

enum DisplayIO {
    /// macos.check: CGError → human-readable error.
    static func check(_ code: CGError, _ operation: String) throws {
        if code != .success {
            throw HiDPIError("\(operation) failed, CoreGraphics error \(code.rawValue)")
        }
    }

    /// CGGetOnlineDisplayList (capped at 128, like Python).
    static func onlineIDs() throws -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 128)
        var count: UInt32 = 0
        try check(CGGetOnlineDisplayList(128, &ids, &count), "Reading displays")
        return Array(ids.prefix(Int(count)))
    }

    /// macos.info: CGDisplayMode → ModeInfo (imported into Swift as property access).
    static func info(_ mode: CGDisplayMode) -> ModeInfo {
        ModeInfo(width: mode.width, height: mode.height,
                 pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                 hz: mode.refreshRate,
                 modeID: UInt32(bitPattern: mode.ioDisplayModeID),
                 flags: mode.ioFlags,
                 usable: mode.isUsableForDesktopGUI())
    }

    /// The current mode. A full port of macos.current: for virtual displays (0xF0F0) with no
    /// CG mode, fall back to NSScreen (during startup CG may only publish NSScreen data;
    /// hz is unknown and recorded as 0 — Modes.modeMatchesLenient's tolerance for hz=0
    /// exists exactly for this). CGDisplayCopy* follows the +1 convention; ARC releases.
    static func currentMode(_ display: CGDirectDisplayID) -> ModeInfo? {
        if let mode = CGDisplayCopyDisplayMode(display) { return info(mode) }
        guard CGDisplayVendorNumber(display) == VirtualBridge.vendorID else { return nil }
        return screenMode(display)
    }

    /// macos.screen_mode: read the fallback mode from NSScreen's deviceDescription.
    private static func screenMode(_ display: CGDirectDisplayID) -> ModeInfo? {
        for screen in NSScreen.screens {
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

    /// macos.modes: the full mode list including kCGDisplayShowDuplicateLowResolutionModes.
    /// CFArray → [CGDisplayMode] bridging retains each reference.
    static func allModes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let array = CGDisplayCopyAllDisplayModes(display, options) else { return [] }
        return array as? [CGDisplayMode] ?? []
    }
}
