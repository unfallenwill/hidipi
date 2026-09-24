/// 移植 hidipi/src/hidipi/modes.py：纯显示模式选择、比较与尺寸解析。
import Foundation

/// 一份显示模式描述；字段与 Python 备份 JSON 完全一致（见 Backup.swift 的编码键）。
public struct ModeInfo: Equatable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hz: Double
    public var modeID: UInt32
    public var flags: UInt32
    public var usable: Bool

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
                hz: Double, modeID: UInt32 = 0, flags: UInt32 = 0, usable: Bool = true) {
        self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.hz = hz; self.modeID = modeID; self.flags = flags; self.usable = usable
    }

    enum CodingKeys: String, CodingKey {
        case width, height
        case pixelWidth = "pixel_width", pixelHeight = "pixel_height"
        case hz, usable, flags
        case modeID = "mode_id"
    }
}

public enum Modes {
    /// modes.mode_matches：尺寸与像素完全一致，刷新率容差 0.6 Hz。
    public static func modeMatches(_ actual: ModeInfo?, _ expected: ModeInfo) -> Bool {
        guard let a = actual else { return false }
        return a.width == expected.width && a.height == expected.height
            && a.pixelWidth == expected.pixelWidth && a.pixelHeight == expected.pixelHeight
            && abs(a.hz - expected.hz) < 0.6
    }

    /// modes.is_hidpi：像素按逻辑尺寸的 2 倍及以上渲染。
    public static func isHiDPI(_ mode: ModeInfo?) -> Bool {
        guard let m = mode else { return false }
        return m.pixelWidth >= 2 * m.width && m.pixelHeight >= 2 * m.height
    }

    /// modes.describe。
    public static func describe(_ mode: ModeInfo?) -> String {
        guard let m = mode else { return "模式暂不可用" }
        let rate = m.hz != 0 ? "\(formatG(m.hz)) Hz" : "刷新率未报告"
        return "\(m.width)×\(m.height)，渲染 \(m.pixelWidth)×\(m.pixelHeight)，\(rate)，"
            + (isHiDPI(m) ? "HiDPI" : "普通 DPI")
    }

    /// modes.choose_mode：在可用 HiDPI 模式里选逻辑尺寸匹配者；
    /// 优先保持当前刷新率，否则取最高刷新率；绝不明示降级到 LoDPI 变体。
    public static func chooseMode(_ modes: [ModeInfo], size: (Int, Int),
                                  current: ModeInfo, refresh: Double? = nil) throws -> ModeInfo {
        let candidates = modes.filter {
            $0.usable && isHiDPI($0) && ($0.width, $0.height) == size
                && (refresh == nil || abs($0.hz - refresh!) < 0.6)
        }
        guard !candidates.isEmpty else {
            var requested = "\(size.0)×\(size.1)"
            if let refresh { requested += " @ \(formatG(refresh)) Hz" }
            throw HiDPIError("系统没有提供 \(requested) 的 HiDPI 模式；未修改设置。"
                + "请运行 list 选择已有模式。本工具不会伪造显示器配置。")
        }
        // Python 键 (刷新率不一致, -刷新率) 的字典序：先比一致性，再取更高刷新率。
        return candidates.min {
            let l = (abs($0.hz - current.hz) >= 0.6, -$0.hz)
            let r = (abs($1.hz - current.hz) >= 0.6, -$1.hz)
            return l.0 != r.0 ? l.0 == false : l.1 < r.1
        }!
    }

    /// virtual.mode_matches：尺寸/像素同 modeMatches，但任一方刷新率未知（0）时
    /// 跳过刷新率比较 —— 虚拟屏上线初期 CG 可能暂不报告 hz，不应因此判定失配。
    public static func modeMatchesLenient(_ actual: ModeInfo?, _ expected: ModeInfo) -> Bool {
        guard let a = actual else { return false }
        let rate = (a.hz != 0 && expected.hz != 0) ? a.hz : 0
        var adjusted = a; adjusted.hz = rate
        var target = expected; target.hz = rate != 0 ? expected.hz : 0
        return modeMatches(adjusted, target)
    }

    /// list_displays 的菜单去重：同一逻辑尺寸只保留一个可用 HiDPI 模式 ——
    /// 优先与当前刷新率一致（±0.6 Hz）者，同类中取最高；结果按尺寸升序，与输入顺序无关。
    public static func hidpiChoices(_ modes: [ModeInfo], current: ModeInfo) -> [ModeInfo] {
        // 与 chooseMode 同序：先比是否贴近当前刷新率，再比更高刷新率（本工具链无元组比较，逐分量写）。
        func preferred(_ a: ModeInfo, over b: ModeInfo) -> Bool {
            let aOff = abs(a.hz - current.hz) >= 0.6, bOff = abs(b.hz - current.hz) >= 0.6
            return aOff != bOff ? !aOff : a.hz > b.hz
        }
        var best: [String: ModeInfo] = [:]
        for mode in modes where mode.usable && isHiDPI(mode) {
            let key = "\(mode.width)x\(mode.height)"
            if let existing = best[key], !preferred(mode, over: existing) { continue }
            best[key] = mode
        }
        return best.values.sorted { ($0.width, $0.height) < ($1.width, $1.height) }
    }

    /// modes.size_value：接受 1920x1080 / 1920×1080。
    public static func parseSize(_ value: String) throws -> (Int, Int) {
        let parts = value.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
              640...7680 ~= w, 480...4320 ~= h else {
            throw HiDPIError("请使用 1920x1080 格式；宽 640–7680、高 480–4320。")
        }
        return (w, h)
    }

    /// 近似 Python 的 %g：整数去掉小数点，其余去掉尾零（刷新率范围足够）。
    public static func formatG(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value))
        }
        var text = String(format: "%.6g", value)
        if text.contains(".") { while text.hasSuffix("0") { text.removeLast() } ; if text.hasSuffix(".") { text.removeLast() } }
        return text
    }
}
