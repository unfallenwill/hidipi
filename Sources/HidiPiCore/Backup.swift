/// 移植 hidipi/src/hidipi/backup.py：与 Python 版完全互通的备份快照。
/// 字段名（snake_case）、校验规则、原子写入与回读核验逐条对应。
import Foundation

public struct DisplaySnapshot: Equatable, Codable, Sendable {
    public var id: UInt32
    public var uuid: String
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var builtin: Bool
    public var main: Bool
    public var mirrorOf: UInt32
    public var inMirrorSet: Bool
    public var origin: [Int]
    public var millimeters: [Double]
    public var mode: ModeInfo?

    public init(id: UInt32, uuid: String, vendor: UInt32, model: UInt32, serial: UInt32,
                builtin: Bool, main: Bool, mirrorOf: UInt32, inMirrorSet: Bool,
                origin: [Int], millimeters: [Double], mode: ModeInfo?) {
        self.id = id; self.uuid = uuid; self.vendor = vendor; self.model = model
        self.serial = serial; self.builtin = builtin; self.main = main
        self.mirrorOf = mirrorOf; self.inMirrorSet = inMirrorSet
        self.origin = origin; self.millimeters = millimeters; self.mode = mode
    }

    enum CodingKeys: String, CodingKey {
        case id, uuid, vendor, model, serial, builtin, main
        case mirrorOf = "mirror_of", inMirrorSet = "in_mirror_set"
        case origin, millimeters, mode
    }
}

public struct BackupSnapshot: Equatable, Codable, Sendable {
    public var schema: Int
    public var created: String
    public var macos: String
    public var headless: Bool?
    public var systemFallback: [DisplaySnapshot]?
    public var displays: [DisplaySnapshot]

    /// schema 1 常规快照。
    public init(created: String, macos: String, displays: [DisplaySnapshot]) {
        self.schema = 1; self.created = created; self.macos = macos
        self.headless = nil; self.systemFallback = nil; self.displays = displays
    }

    /// schema 2 无头快照（virtual.capture_original 的空屏分支）。
    public init(headlessCreated created: String, macos: String, systemFallback: [DisplaySnapshot]?) {
        self.schema = 2; self.created = created; self.macos = macos
        self.headless = true; self.systemFallback = systemFallback; self.displays = []
    }

    enum CodingKeys: String, CodingKey {
        case schema, created, macos, displays, headless
        case systemFallback = "system_fallback"
    }
}

public enum Backup {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]   // NaN/Inf 编码默认抛错 = allow_nan=False
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .throw
        return d
    }

    /// backup.validate_backup 的逐条移植。
    public static func validate(_ snapshot: BackupSnapshot) throws {
        if snapshot.schema == 2, snapshot.headless == true, snapshot.displays.isEmpty { return }
        guard snapshot.schema == 1 else { throw HiDPIError("不支持的备份格式。") }
        guard (1...128).contains(snapshot.displays.count) else {
            throw HiDPIError("备份显示器列表无效。")
        }
        var ids = Set<UInt32>(), uuids = Set<String>()
        do {
            for item in snapshot.displays {
                guard item.id > 0 else { throw HiDPIError("") }
                guard !ids.contains(item.id), !uuids.contains(item.uuid) else { throw HiDPIError("") }
                guard UUID(uuidString: item.uuid) != nil else { throw HiDPIError("") }
                ids.insert(item.id); uuids.insert(item.uuid)
                guard item.origin.count == 2, item.origin.allSatisfy({ abs($0) < (1 << 31) }) else {
                    throw HiDPIError("")
                }
                guard let mode = item.mode else { throw HiDPIError("") }
                for dim in [mode.width, mode.height, mode.pixelWidth, mode.pixelHeight] {
                    guard (0...65536).contains(dim), dim > 0 else { throw HiDPIError("") }
                }
                guard mode.hz.isFinite, (0...1000).contains(mode.hz) else { throw HiDPIError("") }
            }
            guard snapshot.displays.allSatisfy({ d in
                d.mirrorOf == 0 || (ids.contains(d.mirrorOf) && d.mirrorOf != d.id)
            }) else { throw HiDPIError("") }
        } catch {
            throw HiDPIError("备份数据不完整或数值无效；未修改显示器。")
        }
    }

    public static func decode(_ data: Data) throws -> BackupSnapshot {
        let snapshot = try decoder.decode(BackupSnapshot.self, from: data)
        try validate(snapshot)
        return snapshot
    }

    /// backup.write_backup：原子写入 + 回读核验；任何修改显示器之前完成。
    @discardableResult
    public static func write(_ snapshot: BackupSnapshot, to directory: URL) throws -> URL {
        try validate(snapshot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let path = directory.appendingPathComponent("display-\(formatter.string(from: Date()))-\(suffix).json")

        var data = try encoder.encode(snapshot)
        data.append(0x0A)  // 尾部换行，与 Python json.dump 一致

        let temporary = directory.appendingPathComponent(".backup-\(UUID().uuidString.prefix(8))")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw HiDPIError("无法创建备份临时文件：\(temporary.path)") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + written, buffer.count - written)
                if n <= 0 { throw HiDPIError("写入备份失败。") }
                written += n
            }
        }
        Darwin.fsync(fd)
        Darwin.close(fd)
        try FileManager.default.moveItem(at: temporary, to: path)
        let dirFD = Darwin.open(directory.path, O_RDONLY)
        if dirFD >= 0 { Darwin.fsync(dirFD); Darwin.close(dirFD) }

        // 回读核验，之后才允许改动显示器。
        let readBack = try decode(try String(contentsOf: path, encoding: .utf8).data(using: .utf8)!)
        guard readBack == snapshot else { throw HiDPIError("备份回读不一致；取消切换。") }
        return path
    }

    /// 当前时间的 ISO8601（带时区与微秒），对应 Python datetime.isoformat()。
    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// 对应 platform.mac_ver()[0] 的主.次版本号。
    public static func macosVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}
