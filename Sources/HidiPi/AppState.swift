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
    private(set) var originalSnapshot: DisplayState?   // From before the first modification
    private(set) var modifiedDisplayID: CGDirectDisplayID?

    // —— Virtual display state ——
    private(set) var virtualController: VirtualDisplayController?
    private(set) var virtualOriginal: DisplayState?
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
        lock = try OperationLock()
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
        // snapshot() hands out validated states — this is the rollback reference.
        let original = try service.snapshot()
        if originalSnapshot == nil {
            originalSnapshot = original
        }
        modifiedDisplayID = target.id
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

    /// Shared virtual teardown: close the display, drop state, optionally clear the
    /// preference record, then restore the captured original.
    private func dismantleVirtual(clearPreference: Bool) throws {
        guard let controller = virtualController else { return }
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

    /// clearPreference: true when the user explicitly removes (clears the desired state);
    /// false on unexpected-disappearance cleanup (keeps the record so the next login rebuilds).
    func removeVirtual(clearPreference: Bool = true) throws {
        try beginOperation()
        defer { operationInProgress = false }
        try dismantleVirtual(clearPreference: clearPreference)
    }

    /// Rebuilds the virtual display from the recorded preference after login launch.
    /// Returns true when a rebuild happened; throws on failure (caller may offer retry).
    func restorePreferredVirtual() throws -> Bool {
        guard virtualController == nil, let size = VirtualPreference.load() else { return false }
        NSLog("hidipi: virtual display preference found, rebuilding %@.", "\(size.0)×\(size.1)")
        do {
            try createVirtual(size: size)
            return true
        } catch {
            NSLog("hidipi: automatic rebuild failed: %@", String(describing: error))
            throw error
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
    }

    /// Full cleanup before quitting; on failure the caller decides whether to quit anyway
    /// (physical mode changes still auto-revert on process exit via the app-only scope).
    /// The preference record is kept so the next login rebuilds the virtual display.
    func teardown() throws {
        try dismantleVirtual(clearPreference: false)
        try restoreOriginalQuietly()
        lock = nil
    }

    // MARK: - Menu data

    /// The menu version of list_displays: mode enumeration goes through CG; the
    /// dedup/sorting pure logic lives in Modes.hidpiChoices.
    static func hidpiOptions(for display: DisplaySnapshot) -> [ModeOption] {
        guard let current = display.mode else { return [] }
        return Modes.hidpiChoices(DisplayIO.allModes(display.id).map(DisplayIO.info), current: current)
            .map { ModeOption(display: display, mode: $0) }
    }
}
