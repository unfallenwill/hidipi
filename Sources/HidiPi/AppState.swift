/// Owns display sessions and serializes user operations with display-change recovery.
/// Callers enter on the main thread; system callbacks are dispatched there by AppDelegate.
import Foundation
import HidiPiCore
import CoreGraphics

final class AppState {
    private enum Session {
        case idle
        case physical(original: DisplayState, displayID: UInt32?)
        case virtual(controller: any VirtualDisplayControlling, original: DisplayState, size: (Int, Int)?)
        // The display is already closed, but the original desktop still needs restoring.
        case recovery(DisplayState)
    }

    let service: any DisplayServicing
    private let preferences: VirtualPreferenceStore
    private let makeVirtual: () -> any VirtualDisplayControlling
    private let schedule: (@escaping () -> Void) -> Void
    private var session: Session = .idle
    private(set) var lock: OperationLock?
    private(set) var operationInProgress = false
    private var reconciliationPending = false
    private var reconciliationScheduled = false
    var onReconciled: () -> Void = {}
    var onRecoveryError: (Error) -> Void = {
        NSLog("hidipi: display recovery failed: %@ (state kept, retried on quit)", String(describing: $0))
    }

    var physicalModified: Bool {
        if case .physical = session { return true }
        return false
    }
    var modifiedDisplayID: UInt32? {
        if case .physical(_, let id) = session { return id }
        return nil
    }
    var virtualController: (any VirtualDisplayControlling)? {
        if case .virtual(let controller, _, _) = session { return controller }
        return nil
    }
    var virtualActive: Bool { virtualController != nil }
    var virtualSize: (Int, Int)? {
        if case .virtual(_, _, let size) = session { return size }
        return nil
    }
    var restorationPending: Bool {
        if case .recovery = session { return true }
        return false
    }

    init(service: any DisplayServicing = DisplayService(),
         originalSnapshot: DisplayState? = nil,
         modifiedDisplayID: UInt32? = nil,
         virtualController: (any VirtualDisplayControlling)? = nil,
         virtualOriginal: DisplayState? = nil,
         virtualSize: (Int, Int)? = nil,
         preferences: VirtualPreferenceStore = VirtualPreferenceStore(),
         makeVirtual: (() -> any VirtualDisplayControlling)? = nil,
         schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.service = service
        self.preferences = preferences
        self.makeVirtual = makeVirtual ?? { VirtualDisplayController(service: service) }
        self.schedule = schedule
        if let controller = virtualController {
            session = .virtual(controller: controller,
                               original: virtualOriginal ?? DisplayState(displays: []), size: virtualSize)
        } else if let original = originalSnapshot {
            session = .physical(original: original, displayID: modifiedDisplayID)
        }
    }

    private func withOperation<T>(_ body: () throws -> T) throws -> T {
        guard !operationInProgress else {
            throw HiDPIError("The previous operation is still in progress; try again shortly.")
        }
        operationInProgress = true
        defer {
            operationInProgress = false
            scheduleReconciliationIfNeeded()
        }
        return try body()
    }

    func acquireLock() throws { lock = try OperationLock() }

    func enableHiDPI(on target: DisplaySnapshot, wanted: ModeInfo) throws {
        try withOperation {
            guard !virtualActive, !restorationPending else {
                throw HiDPIError("Remove the virtual display and finish restoring before changing physical displays.")
            }
            guard !target.inMirrorSet else {
                throw HiDPIError("The target display is mirroring. Disable mirroring in System Settings first.")
            }
            guard let current = target.mode else {
                throw HiDPIError("Cannot read the original mode, so no safe rollback is possible; cancelled.")
            }
            if Modes.modeMatches(current, wanted) { return }
            let fresh = try service.snapshot()
            let original: DisplayState
            if case .physical(let saved, _) = session {
                original = saved
            } else {
                original = fresh
            }
            session = .physical(original: original, displayID: target.id)
            do {
                try service.setMode(target.id, expected: wanted)
                try service.waitUntil(timeout: 5, "The system did not switch to the requested HiDPI mode; rolling back") {
                    Modes.modeMatches(service.currentMode(target.id), wanted)
                }
            } catch {
                try rollback(after: error)
            }
        }
    }

    func createVirtual(size: (Int, Int)) throws {
        try withOperation {
            guard case .idle = session else {
                throw HiDPIError("A display change is already active or awaiting restore; restore it before creating a virtual display.")
            }
            try VirtualDisplayController.validateOptions(size: size, refresh: 60)
            let original = try VirtualDisplay.captureOriginal(service)
            let controller = makeVirtual()
            do {
                let id = try controller.start(size: size, refresh: 60)
                try preferences.save(size)
                // Publish the active session only after all creation steps succeed.
                session = .virtual(controller: controller, original: original, size: size)
                NSLog("hidipi: virtual display verified, ID=%u", id)
            } catch {
                session = .recovery(original)
                controller.close()
                try rollback(after: error)
            }
        }
    }

    /// Keep the rollback reference until restoration succeeds, including after close().
    private func restoreSession(clearPreference: Bool) throws {
        switch session {
        case .idle:
            return
        case .virtual(let controller, let original, _):
            session = .recovery(original)
            controller.close()
            if clearPreference { preferences.clear() }
            try service.restoreConnected(original)
        case .physical(let original, _), .recovery(let original):
            try service.restoreConnected(original)
        }
        session = .idle
    }

    private func rollback(after error: Error) throws -> Never {
        do {
            try restoreSession(clearPreference: false)
        } catch let restoreError {
            throw HiDPIError("\(error)\nRollback also failed: \(restoreError). Original settings are kept for a retry on quit.")
        }
        throw error
    }

    func removeVirtual(clearPreference: Bool = true) throws {
        try withOperation {
            guard virtualActive || restorationPending else { return }
            // Also allow explicit removal after an earlier failed rollback.
            if clearPreference && restorationPending { preferences.clear() }
            try restoreSession(clearPreference: clearPreference)
        }
    }

    func restorePreferredVirtual() throws -> Bool {
        guard case .idle = session, let size = preferences.load() else { return false }
        try createVirtual(size: size)
        return true
    }

    func restoreOriginalQuietly() throws {
        try withOperation {
            guard physicalModified || restorationPending else { return }
            try restoreSession(clearPreference: false)
        }
    }

    func teardown() throws {
        try withOperation {
            try restoreSession(clearPreference: false)
            reconciliationPending = false
            lock = nil
        }
    }

    // Display callbacks only request work. Events arriving inside a pumped run loop are
    // coalesced and reconciled after the active operation has committed or rolled back.
    func requestDisplayReconciliation() {
        reconciliationPending = true
        scheduleReconciliationIfNeeded()
    }

    private func scheduleReconciliationIfNeeded() {
        guard reconciliationPending, !operationInProgress, !reconciliationScheduled else { return }
        reconciliationScheduled = true
        schedule { [weak self] in
            guard let self else { return }
            self.reconciliationScheduled = false
            guard self.reconciliationPending, !self.operationInProgress else { return }
            self.reconciliationPending = false
            do {
                try self.withOperation {
                    if let id = self.modifiedDisplayID, !self.service.isOnline(id) {
                        try self.restoreSession(clearPreference: false)
                    } else if let controller = self.virtualController,
                              !self.service.isOnline(controller.displayID) {
                        try self.restoreSession(clearPreference: false)
                    }
                }
            } catch {
                self.onRecoveryError(error)
            }
            self.onReconciled()
        }
    }

    static func hidpiOptions(for display: DisplaySnapshot) -> [ModeOption] {
        modeOptions(for: display, modes: DisplayService().allModes(display.id))
    }

    func hidpiOptions(for display: DisplaySnapshot) -> [ModeOption] {
        Self.modeOptions(for: display, modes: service.allModes(display.id))
    }

    private static func modeOptions(for display: DisplaySnapshot, modes: [ModeInfo]) -> [ModeOption] {
        guard let current = display.mode else { return [] }
        return Modes.hidpiChoices(modes, current: current).map { ModeOption(display: display, mode: $0) }
    }
}
