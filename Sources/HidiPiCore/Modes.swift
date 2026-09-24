/// Port of hidipi/src/hidipi/modes.py: pure display-mode selection, comparison and size parsing.
import Foundation

/// A display mode description; field names mirror the Python version's model.
public struct ModeInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hz: Double
    public var modeID: UInt32
    public var usable: Bool

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
                hz: Double, modeID: UInt32 = 0, usable: Bool = true) {
        self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.hz = hz; self.modeID = modeID; self.usable = usable
    }
}

public enum Modes {
    /// Rates within 0.6 Hz count as equal everywhere (the modeMatches tolerance).
    private static func closeRate(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.6
    }

    /// The ordering shared by chooseMode and hidpiChoices: closeness to the current
    /// refresh rate first, then the higher rate.
    private static func preferred(_ a: ModeInfo, over b: ModeInfo, current: ModeInfo) -> Bool {
        let aOff = !closeRate(a.hz, current.hz), bOff = !closeRate(b.hz, current.hz)
        return aOff != bOff ? !aOff : a.hz > b.hz
    }

    /// modes.mode_matches: identical size and pixels, refresh rate within 0.6 Hz.
    public static func modeMatches(_ actual: ModeInfo?, _ expected: ModeInfo) -> Bool {
        guard let a = actual else { return false }
        return a.width == expected.width && a.height == expected.height
            && a.pixelWidth == expected.pixelWidth && a.pixelHeight == expected.pixelHeight
            && closeRate(a.hz, expected.hz)
    }

    /// modes.is_hidpi: pixels rendered at 2x or more of the logical size.
    public static func isHiDPI(_ mode: ModeInfo?) -> Bool {
        guard let m = mode else { return false }
        return m.pixelWidth >= 2 * m.width && m.pixelHeight >= 2 * m.height
    }

    /// modes.describe.
    public static func describe(_ mode: ModeInfo?) -> String {
        guard let m = mode else { return "Mode unavailable" }
        let rate = m.hz != 0 ? "\(formatG(m.hz)) Hz" : "refresh rate not reported"
        return "\(m.width)×\(m.height), rendered \(m.pixelWidth)×\(m.pixelHeight), \(rate), "
            + (isHiDPI(m) ? "HiDPI" : "standard DPI")
    }

    /// modes.choose_mode: among usable HiDPI modes pick the one matching the logical size;
    /// prefer keeping the current refresh rate, otherwise the highest rate; never silently
    /// downgrade to a LoDPI variant.
    public static func chooseMode(_ modes: [ModeInfo], size: (Int, Int),
                                  current: ModeInfo, refresh: Double? = nil) throws -> ModeInfo {
        let candidates = modes.filter {
            $0.usable && isHiDPI($0) && ($0.width, $0.height) == size
                && (refresh == nil || closeRate($0.hz, refresh!))
        }
        guard !candidates.isEmpty else {
            var requested = "\(size.0)×\(size.1)"
            if let refresh { requested += " @ \(formatG(refresh)) Hz" }
            throw HiDPIError("No HiDPI mode available for \(requested); settings unchanged. "
                + "Run list to pick an existing mode. This tool does not fabricate display configurations.")
        }
        return candidates.min { preferred($0, over: $1, current: current) }!
    }

    /// virtual.mode_matches: same dimensions/pixels as modeMatches, but skips the refresh-rate
    /// comparison when either side reports 0 — CG may briefly omit hz while a virtual display
    /// comes online, which must not count as a mismatch.
    public static func modeMatchesLenient(_ actual: ModeInfo?, _ expected: ModeInfo) -> Bool {
        guard let a = actual else { return false }
        let rate = (a.hz != 0 && expected.hz != 0) ? a.hz : 0
        var adjusted = a; adjusted.hz = rate
        var target = expected; target.hz = rate != 0 ? expected.hz : 0
        return modeMatches(adjusted, target)
    }

    /// list_displays menu dedup: keep one usable HiDPI mode per logical size — prefer the one
    /// matching the current refresh rate, otherwise the highest rate within the same class;
    /// results sorted by size ascending, independent of input order.
    public static func hidpiChoices(_ modes: [ModeInfo], current: ModeInfo) -> [ModeInfo] {
        var best: [String: ModeInfo] = [:]
        for mode in modes where mode.usable && isHiDPI(mode) {
            let key = "\(mode.width)x\(mode.height)"
            if let existing = best[key], !preferred(mode, over: existing, current: current) { continue }
            best[key] = mode
        }
        return best.values.sorted { ($0.width, $0.height) < ($1.width, $1.height) }
    }

    /// modes.size_value: accepts 1920x1080 / 1920×1080.
    public static func parseSize(_ value: String) throws -> (Int, Int) {
        let parts = value.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
              640...7680 ~= w, 480...4320 ~= h else {
            throw HiDPIError("Use the 1920x1080 format; width 640–7680, height 480–4320.")
        }
        return (w, h)
    }

    /// Approximates Python's %g: drop the decimal point for integers, otherwise strip
    /// trailing zeros (sufficient for refresh-rate magnitudes).
    public static func formatG(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value))
        }
        var text = String(format: "%.6g", value)
        if text.contains(".") { while text.hasSuffix("0") { text.removeLast() } ; if text.hasSuffix(".") { text.removeLast() } }
        return text
    }
}
