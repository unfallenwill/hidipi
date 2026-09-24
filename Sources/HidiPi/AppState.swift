/// App state and all operation flows (enable / virtual / quit).
/// Follows the Python version's semantics: only one modification at a time (physical OR
/// virtual, enforced by entry guards rather than menu disabling); restored on quit or
/// removal from in-memory snapshots. All methods must be called on the main thread.
import Foundation
import HidiPiCore
import CoreGraphics

final class AppState {
    let service = DisplayService()
    private(set) var lock: OperationLock?

    // —— Physical display modification state ——
    private(set) var originalSnapshot: BackupSnapshot?   // Full snapshot from before the first modification
    private(set) var modifiedDisplayID: CGDirectDisplayID?
    private(set) var modifiedUUID: String?

    // —— Virtual display state ——
    private(set) var virtualController: VirtualDisplayController?
    private(set) var virtualOriginal: BackupSnapshot?
    private(set) var virtualSize: (Int, Int)?

    var physicalModified: Bool { originalSnapshot != nil }
    var virtualActive: Bool { virtualController != nil }

    // —— Reentrancy guard ——
    // waitUntil pumps the run loop and NSAlert.runModal nests event loops, so menu actions
    // can fire while an operation is in flight; this flag keeps "one modification at a time"
    // from depending on menu disabling.
    private var operationInProgress = false

    /// Entry mutex for mutating operations: rejects reentry while one is in flight.
    private func beginOperation() throws {
        guard !operationInProgress else {
            throw HiDPIError("The previous operation is still in progress; try again shortly.")
        }
        operationInProgress = true
    }

    /// Acquires at startup the operation lock mutual with the Python version.
    func acquireLock() throws {
        lock = try OperationLock(filename: "operation.lock")
    }

    // MARK: - Physical HiDPI (port of display.enable_hidpi, minus the preview phase)

    /// target comes from a freshly rebuilt snapshot; wanted is the menu-selected HiDPI mode.
    func enableHiDPI(on target: DisplaySnapshot, wanted: ModeInfo) throws {
        guard !virtualActive else {
            throw HiDPIError("A virtual display is active; remove it before changing physical displays.")
        }
        try beginOperation()
        defer { operationInProgress = false }
        guard !target.inMirrorSet else {
            throw HiDPIError("The target display is mirroring. Disable mirroring in System Settings first.")
        }
        guard let current = target.mode else {
            throw HiDPIError("Cannot read the original mode, so no safe rollback is possible; cancelled.")
        }
        if Modes.modeMatches(current, wanted) { return }   // already in that mode
        let original = try service.snapshot()
        // The snapshot is the rollback reference — validate it before touching any display.
        try Backup.validate(original)
        if originalSnapshot == nil {
            originalSnapshot = original
        }
        modifiedDisplayID = target.id
        modifiedUUID = target.uuid
        do {
            try service.setMode(target.id, expected: wanted)
            try service.waitUntil(timeout: 5, "The system did not switch to the requested HiDPI mode; rolling back") {
                Modes.modeMatches(DisplayIO.currentMode(target.id), wanted)
            }
        } catch {
            try? restoreOriginalQuietly()
            throw error
        }
    }

    // MARK: - Virtual display (port of virtual.run)

    func createVirtual(size: (Int, Int)) throws {
        guard !physicalModified else {
            throw HiDPIError("Physical display changes are not restored yet; exit that change before creating a virtual display.")
        }
        try beginOperation()
        defer { operationInProgress = false }
        try VirtualDisplayController.validateOptions(size: size, refresh: 60)
        let original = try VirtualDisplay.captureOriginal(service)
        try Backup.validate(original)
        let controller = VirtualDisplayController(service: service)
        do {
            let id = try controller.start(size: size, refresh: 60)
            NSLog("hidipi: virtual display verified, ID=%u", id)
            virtualController = controller
            virtualOriginal = original
            virtualSize = size
            // Remember the desired state: rebuilt automatically after restart / login launch.
            try VirtualPreference.save(size)
        } catch {
            controller.close()
            try? service.restoreConnected(original)
            throw error
        }
    }

    /// clearPreference: true when the user explicitly removes (clears the desired state);
    /// false on unexpected-disappearance cleanup (keeps the record so the next login rebuilds).
    func removeVirtual(clearPreference: Bool = true) throws {
        guard let controller = virtualController else { return }
        try beginOperation()
        defer { operationInProgress = false }
        virtualController = nil
        controller.close()
        let original = virtualOriginal
        virtualOriginal = nil
        virtualSize = nil
        if clearPreference { VirtualPreference.clear() }
        if let original {
            try service.restoreConnected(original)   // failure propagates
        }
    }

    /// Rebuilds the virtual display from the recorded preference after login launch;
    /// silently skipped when no record exists or one is already running.
    /// Returns nil when nothing to do / rebuilt; non-nil on failure (caller may offer retry).
    @discardableResult
    func restorePreferredVirtual() -> Error? {
        guard virtualController == nil, let size = VirtualPreference.load() else { return nil }
        NSLog("hidipi: virtual display preference found, rebuilding %@.", "\(size.0)×\(size.1)")
        do {
            try createVirtual(size: size)
            return nil
        } catch {
            NSLog("hidipi: automatic rebuild failed: %@", String(describing: error))
            return error
        }
    }

    // MARK: - Quit-time cleanup (the Python version's finally-restore)

    /// Best-effort restore for callback safety nets; if restore throws, state is
    /// intentionally kept so quit retries it.
    func restoreOriginalQuietly() throws {
        if let original = originalSnapshot {
            try service.restoreConnected(original)
        }
        originalSnapshot = nil
        modifiedDisplayID = nil
        modifiedUUID = nil
    }

    /// Full cleanup before quitting; on failure the caller decides whether to quit anyway
    /// (physical mode changes still auto-revert on process exit via the app-only scope).
    func teardown() throws {
        if let controller = virtualController {
            virtualController = nil
            controller.close()
            if let original = virtualOriginal {
                try service.restoreConnected(original)
            }
            virtualOriginal = nil
            virtualSize = nil
        }
        if let original = originalSnapshot {
            try service.restoreConnected(original)
            originalSnapshot = nil
            modifiedDisplayID = nil
            modifiedUUID = nil
        }
        lock = nil
    }

    // MARK: - Menu data

    struct ModeOption {
        let mode: ModeInfo
        var label: String { "\(mode.width)×\(mode.height) (\(Modes.formatG(mode.hz)) Hz)" }
    }

    /// The menu version of list_displays: mode enumeration goes through CG; the
    /// dedup/sorting pure logic lives in Modes.hidpiChoices.
    static func hidpiOptions(for display: DisplaySnapshot) -> [ModeOption] {
        guard let current = display.mode else { return [] }
        return Modes.hidpiChoices(DisplayIO.allModes(display.id).map(DisplayIO.info), current: current)
            .map { ModeOption(mode: $0) }
    }
}
