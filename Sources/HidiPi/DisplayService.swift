/// Port of the Mac class in macos.py: snapshotting, switching, restore transactions and
/// verification — the safety core.
import Foundation
import HidiPiCore
import CoreGraphics

struct DisplayService {
    /// macos.snapshot: the full state of all online displays.
    func snapshot(allowEmpty: Bool = false) throws -> BackupSnapshot {
        var displays: [DisplaySnapshot] = []
        for display in try DisplayIO.onlineIDs() {
            let bounds = CGDisplayBounds(display)
            let size = CGDisplayScreenSize(display)
            displays.append(DisplaySnapshot(
                id: display,
                uuid: try DisplayUUID.string(for: display),
                vendor: CGDisplayVendorNumber(display),
                model: CGDisplayModelNumber(display),
                serial: CGDisplaySerialNumber(display),
                builtin: CGDisplayIsBuiltin(display) != 0,
                main: CGDisplayIsMain(display) != 0,
                mirrorOf: CGDisplayMirrorsDisplay(display),
                inMirrorSet: CGDisplayIsInMirrorSet(display) != 0,
                origin: [Int(bounds.origin.x), Int(bounds.origin.y)],
                millimeters: [size.width, size.height],
                mode: DisplayIO.currentMode(display)))
        }
        guard !displays.isEmpty || allowEmpty else {
            throw HiDPIError("No online displays found. Run on this machine's logged-in desktop; "
                + "sandboxed/SSH sessions may not reach WindowServer.")
        }
        if displays.isEmpty {
            return BackupSnapshot(headlessCreated: Backup.timestamp(), macos: Backup.macosVersion(),
                                  systemFallback: nil)
        }
        return BackupSnapshot(created: Backup.timestamp(), macos: Backup.macosVersion(), displays: displays)
    }

    /// macos.pump / wait_until: pumps the run loop while waiting for the predicate to hold.
    func waitUntil(timeout: TimeInterval, _ error: String, _ predicate: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try predicate() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw HiDPIError(error)
    }

    /// macos.set_mode: single-transaction switch (app-only — reverts when the process exits).
    func setMode(_ display: CGDirectDisplayID, expected: ModeInfo) throws {
        let candidates = DisplayIO.allModes(display).filter {
            Modes.modeMatches(DisplayIO.info($0), expected)
        }
        guard let mode = candidates.first else {
            throw HiDPIError("The requested mode is no longer available; nothing was changed.")
        }
        var config: CGDisplayConfigRef?
        try DisplayIO.check(CGBeginDisplayConfiguration(&config), "Beginning display configuration")
        do {
            try DisplayIO.check(CGConfigureDisplayWithDisplayMode(config, display, mode, nil), "Switching HiDPI mode")
            try DisplayIO.check(CGCompleteDisplayConfiguration(config, CGConfigureOption.forAppOnly), "Applying display configuration")
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
    }

    /// macos.restore: resolve by UUID, pre-check every display, then restore mode/layout/
    /// mirroring in a single transaction and verify.
    func restore(_ snapshot: BackupSnapshot) throws {
        if snapshot.schema == 2, snapshot.headless == true, snapshot.displays.isEmpty { return }
        let live = try Dictionary(uniqueKeysWithValues: DisplayIO.onlineIDs().map {
            (try DisplayUUID.string(for: $0), $0)
        })
        // Pre-check everything before touching any display; mode_id only breaks ties
        // (it changes across reboots). CGDisplayMode references are held by the array
        // (CF bridging +0), no manual release needed.
        var entries: [(id: CGDirectDisplayID, mode: CGDisplayMode, saved: DisplaySnapshot)] = []
        for saved in snapshot.displays {
            guard let display = live[saved.uuid] else {
                throw HiDPIError("Display \(saved.uuid) from the snapshot is not connected; reconnect it and retry.")
            }
            guard let wanted = saved.mode else {
                throw HiDPIError("The snapshot is missing the original mode; cannot fully restore.")
            }
            let matches = DisplayIO.allModes(display).filter {
                Modes.modeMatches(DisplayIO.info($0), wanted)
            }
            guard let best = matches.min(by: {
                // Python: mode_id is only a tie-breaker; the matching one sorts first.
                let l = DisplayIO.info($0).modeID != wanted.modeID
                let r = DisplayIO.info($1).modeID != wanted.modeID
                return l != r ? !l : false
            }) else {
                throw HiDPIError("The original mode for display \(display) is currently unavailable: \(Modes.describe(wanted))")
            }
            entries.append((display, best, saved))
        }

        var config: CGDisplayConfigRef?
        try DisplayIO.check(CGBeginDisplayConfiguration(&config), "Beginning display configuration")
        do {
            for e in entries {
                try DisplayIO.check(CGConfigureDisplayMirrorOfDisplay(config, e.id, kCGNullDirectDisplay), "Unmirroring")
            }
            for e in entries {
                try DisplayIO.check(CGConfigureDisplayWithDisplayMode(config, e.id, e.mode, nil), "Restoring original mode")
                if e.saved.mirrorOf == 0 {
                    try DisplayIO.check(CGConfigureDisplayOrigin(config, e.id,
                        Int32(e.saved.origin[0]), Int32(e.saved.origin[1])), "Restoring display layout")
                }
            }
            for e in entries where e.saved.mirrorOf != 0 {
                guard let source = entries.first(where: { $0.saved.id == e.saved.mirrorOf }) else {
                    throw HiDPIError("The snapshot's mirror source is incomplete.")
                }
                try DisplayIO.check(CGConfigureDisplayMirrorOfDisplay(config, e.id, source.id), "Restoring mirroring")
            }
            try DisplayIO.check(CGCompleteDisplayConfiguration(config, CGConfigureOption.permanently), "Applying display configuration")
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
        try waitUntil(timeout: 6, "Post-restore resolution or layout verification failed") {
            entries.allSatisfy { e in
                guard Modes.modeMatches(DisplayIO.currentMode(e.id), e.saved.mode!) else { return false }
                let mirror = CGDisplayMirrorsDisplay(e.id)
                let expectedMirror = e.saved.mirrorOf != 0
                    ? entries.first { $0.saved.id == e.saved.mirrorOf }!.id : kCGNullDirectDisplay
                if mirror != expectedMirror { return false }
                if e.saved.mirrorOf == 0 {
                    let bounds = CGDisplayBounds(e.id)
                    if [Int(bounds.origin.x), Int(bounds.origin.y)] != e.saved.origin { return false }
                }
                return true
            }
        }
    }

    /// virtual.restore_connected: restore only displays still online.
    func restoreConnected(_ snapshot: BackupSnapshot) throws {
        guard snapshot.schema != 2 else { return }
        let live = Set(try DisplayIO.onlineIDs().map { try DisplayUUID.string(for: $0) })
        let connected = snapshot.displays.filter { live.contains($0.uuid) }
        if connected.count != snapshot.displays.count {
            NSLog("hidipi: some original displays are disconnected; their settings cannot be restored.")
        }
        guard !connected.isEmpty else { return }
        let ids = Set(connected.map(\.id))
        if connected.contains(where: { $0.mirrorOf != 0 && !ids.contains($0.mirrorOf) }) {
            throw HiDPIError("The original mirror set is incomplete; reconnect the original displays.")
        }
        var partial = snapshot
        partial.displays = connected
        try restore(partial)
    }
}
