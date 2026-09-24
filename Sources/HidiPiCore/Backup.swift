/// Snapshot model shared with the Python version's backup format (hidipi/src/hidipi/backup.py).
/// The app keeps snapshots in memory only, as rollback references — nothing is written to disk.
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

    /// Regular schema 1 snapshot.
    public init(created: String, macos: String, displays: [DisplaySnapshot]) {
        self.schema = 1; self.created = created; self.macos = macos
        self.headless = nil; self.systemFallback = nil; self.displays = displays
    }

    /// Headless schema 2 snapshot (the empty-display branch of virtual.capture_original).
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
    /// A rule-by-rule port of backup.validate_backup: a snapshot is only accepted as a
    /// rollback reference if it passes every check.
    public static func validate(_ snapshot: BackupSnapshot) throws {
        if snapshot.schema == 2, snapshot.headless == true, snapshot.displays.isEmpty { return }
        guard snapshot.schema == 1 else { throw HiDPIError("Unsupported snapshot format.") }
        guard (1...128).contains(snapshot.displays.count) else {
            throw HiDPIError("Invalid display list in snapshot.")
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
            throw HiDPIError("Snapshot data incomplete or values invalid; displays unmodified.")
        }
    }

    /// ISO8601 of the current time (with timezone and microseconds), matching Python's
    /// datetime.isoformat().
    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// The major.minor version corresponding to platform.mac_ver()[0].
    public static func macosVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}
