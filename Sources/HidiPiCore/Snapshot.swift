/// Captured display state: the in-memory rollback reference taken before any modification,
/// and the menu's data source. The field layout is inherited from the Python version's
/// snapshot model, but nothing is serialized.
import Foundation

public struct DisplaySnapshot: Equatable, Sendable {
    public var id: UInt32
    public var uuid: String
    public var vendor: UInt32
    public var model: UInt32
    public var main: Bool
    public var mirrorOf: UInt32
    public var inMirrorSet: Bool
    public var origin: [Int]
    public var mode: ModeInfo?

    public init(id: UInt32, uuid: String, vendor: UInt32, model: UInt32,
                main: Bool, mirrorOf: UInt32, inMirrorSet: Bool,
                origin: [Int], mode: ModeInfo?) {
        self.id = id; self.uuid = uuid; self.vendor = vendor; self.model = model
        self.main = main; self.mirrorOf = mirrorOf; self.inMirrorSet = inMirrorSet
        self.origin = origin; self.mode = mode
    }
}

/// The state of all relevant displays at a point in time. An empty `displays` list means
/// no stable displays exist (the headless case, when only macOS's transient fallback
/// desktop is present).
public struct DisplayState: Equatable, Sendable {
    public var displays: [DisplaySnapshot]

    public init(displays: [DisplaySnapshot]) { self.displays = displays }

    /// A rule-by-rule port of backup.validate_backup, minus the wire format: a state is
    /// only accepted as a rollback reference if every check passes. Empty is valid.
    public func validate() throws {
        let invalid = HiDPIError("Snapshot data incomplete or values invalid; displays unmodified.")
        guard displays.isEmpty || (1...128).contains(displays.count) else {
            throw HiDPIError("Invalid display list in snapshot.")
        }
        var ids = Set<UInt32>(), uuids = Set<String>()
        for item in displays {
            guard item.id > 0 else { throw invalid }
            guard !ids.contains(item.id), !uuids.contains(item.uuid) else { throw invalid }
            guard UUID(uuidString: item.uuid) != nil else { throw invalid }
            ids.insert(item.id); uuids.insert(item.uuid)
            guard item.origin.count == 2, item.origin.allSatisfy({ abs($0) < (1 << 31) }) else {
                throw invalid
            }
            guard let mode = item.mode else { throw invalid }
            for dim in [mode.width, mode.height, mode.pixelWidth, mode.pixelHeight] {
                guard (0...65536).contains(dim), dim > 0 else { throw invalid }
            }
            guard mode.hz.isFinite, (0...1000).contains(mode.hz) else { throw invalid }
        }
        guard displays.allSatisfy({ d in
            d.mirrorOf == 0 || (ids.contains(d.mirrorOf) && d.mirrorOf != d.id)
        }) else { throw invalid }
    }
}
