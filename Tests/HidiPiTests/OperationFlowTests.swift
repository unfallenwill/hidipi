import Foundation
import Testing
import HidiPiCore
@testable import HidiPi

private let originalMode = ModeInfo(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, hz: 60)
private let wantedMode = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 60)
private let originalDisplay = DisplaySnapshot(id: 2, uuid: "78589D3B-0A4E-47C1-BF35-FFEA9DABBEB0",
    vendor: 1, model: 1, main: true, mirrorOf: 0, inMirrorSet: false, origin: [0, 0], mode: originalMode)

private final class FakeDisplays: DisplayServicing {
    var mode = originalMode
    var online = true
    var failRestore = false
    var failWait = false
    var onWait: () -> Void = {}
    var onRestore: () -> Void = {}
    var restored: [DisplayState] = []
    var switches = 0

    func snapshot(allowEmpty: Bool) throws -> DisplayState { DisplayState(displays: [originalDisplay]) }
    func setMode(_ display: UInt32, expected: ModeInfo) throws {
        switches += 1
        mode = expected
    }
    func restoreConnected(_ state: DisplayState) throws {
        restored.append(state)
        onRestore()
        if failRestore { throw HiDPIError("restore failed") }
        mode = originalMode
    }
    func waitUntil(timeout: TimeInterval, _ error: String, _ predicate: () throws -> Bool) throws {
        onWait()
        if failWait { throw HiDPIError("verification timed out") }
        guard try predicate() else { throw HiDPIError(error) }
    }
    func currentMode(_ display: UInt32) -> ModeInfo? { mode }
    func isOnline(_ display: UInt32) -> Bool { online }
    func allModes(_ display: UInt32) -> [ModeInfo] { [originalMode, wantedMode] }
}

private final class FakeVirtual: VirtualDisplayControlling {
    var displayID: UInt32 = 9
    var starts = 0
    var closes = 0
    var failStart = false
    var onStart: () -> Void = {}
    func start(size: (Int, Int), refresh: Double) throws -> UInt32 {
        starts += 1
        onStart()
        if failStart { throw HiDPIError("virtual startup timed out") }
        return displayID
    }
    func close() { closes += 1 }
}

private final class Fixture {
    let displays = FakeDisplays()
    let virtual = FakeVirtual()
    var savedSize: (Int, Int)?
    var failSave = false
    var clears = 0
    var jobs: [() -> Void] = []
    lazy var state = AppState(service: displays,
        preferences: VirtualPreferenceStore(
            load: { [unowned self] in savedSize },
            save: { [unowned self] size in
                if failSave { throw HiDPIError("preference write failed") }
                savedSize = size
            },
            clear: { [unowned self] in clears += 1; savedSize = nil }),
        makeVirtual: { [unowned self] in virtual },
        schedule: { [unowned self] in jobs.append($0) })

    func runNextJob() {
        guard !jobs.isEmpty else { return }
        jobs.removeFirst()()
    }
}

@Test func preferenceFailureRollsBackWithoutPublishingAnActiveDisplay() {
    let f = Fixture()
    f.failSave = true
    #expect(throws: HiDPIError.self) { try f.state.createVirtual(size: (1920, 1080)) }
    #expect(!f.state.virtualActive)
    #expect(!f.state.restorationPending)
    #expect(f.virtual.closes == 1)
    #expect(f.displays.restored.count == 1)
    #expect(f.savedSize == nil)
}

@Test func failedCreationAndRollbackKeepTheOriginalForQuitRetry() throws {
    let f = Fixture()
    f.virtual.failStart = true
    f.displays.failRestore = true
    do {
        try f.state.createVirtual(size: (1920, 1080))
        Issue.record("Expected creation to fail")
    } catch {
        #expect(String(describing: error).contains("virtual startup timed out"))
        #expect(String(describing: error).contains("restore failed"))
    }
    #expect(f.state.restorationPending)
    #expect(!f.state.virtualActive)
    #expect(throws: HiDPIError.self) { try f.state.createVirtual(size: (1920, 1080)) }
    #expect(throws: HiDPIError.self) { try f.state.enableHiDPI(on: originalDisplay, wanted: wantedMode) }
    f.displays.failRestore = false
    try f.state.teardown()
    #expect(!f.state.restorationPending)
    #expect(f.displays.restored.count == 2)
    #expect(f.displays.restored[1].displays.first?.uuid == originalDisplay.uuid)
    #expect(f.virtual.closes == 1)
    try f.state.teardown()
    #expect(f.displays.restored.count == 2)
}

@Test func removalFailureRetainsSnapshotAndClearsExplicitPreference() throws {
    let f = Fixture()
    try f.state.createVirtual(size: (1920, 1080))
    f.displays.failRestore = true
    #expect(throws: HiDPIError.self) { try f.state.removeVirtual() }
    #expect(!f.state.virtualActive)
    #expect(f.state.restorationPending)
    #expect(f.savedSize == nil)
    #expect(f.clears == 1)
    f.displays.failRestore = false
    try f.state.teardown()
    #expect(!f.state.restorationPending)
    #expect(f.displays.restored.count == 2)
    #expect(f.virtual.closes == 1)
}

@Test func quitFailureKeepsPreferenceAndAllowsRetry() throws {
    let f = Fixture()
    try f.state.createVirtual(size: (2560, 1440))
    f.displays.failRestore = true
    #expect(throws: HiDPIError.self) { try f.state.teardown() }
    #expect(f.state.restorationPending)
    #expect(f.savedSize?.0 == 2560)
    f.displays.failRestore = false
    try f.state.teardown()
    #expect(f.savedSize?.0 == 2560)
    #expect(!f.state.restorationPending)
}

@Test func duplicateVirtualCreationDoesNotReplaceTheOriginalSession() throws {
    let f = Fixture()
    try f.state.createVirtual(size: (1920, 1080))
    #expect(throws: HiDPIError.self) { try f.state.createVirtual(size: (2560, 1440)) }
    #expect(f.virtual.starts == 1)
    #expect(f.state.virtualSize?.0 == 1920)
    try f.state.teardown()
}

@Test func physicalVerificationTimeoutRestoresTheOriginal() {
    let f = Fixture()
    f.displays.failWait = true
    #expect(throws: HiDPIError.self) { try f.state.enableHiDPI(on: originalDisplay, wanted: wantedMode) }
    #expect(!f.state.physicalModified)
    #expect(f.displays.mode == originalMode)
    #expect(f.displays.restored.count == 1)
}

@Test func physicalRollbackFailureCanBeRetriedOnQuit() throws {
    let f = Fixture()
    f.displays.failWait = true
    f.displays.failRestore = true
    #expect(throws: HiDPIError.self) { try f.state.enableHiDPI(on: originalDisplay, wanted: wantedMode) }
    #expect(f.state.physicalModified)
    f.displays.failRestore = false
    try f.state.teardown()
    #expect(!f.state.physicalModified)
    #expect(f.displays.restored.count == 2)
}

@Test func callbacksDuringPhysicalVerificationWaitForCommitAndCoalesce() throws {
    let f = Fixture()
    f.displays.onWait = {
        f.displays.online = false
        f.state.requestDisplayReconciliation()
        f.state.requestDisplayReconciliation()
        #expect(f.jobs.isEmpty)
        #expect(f.displays.restored.isEmpty)
        #expect(throws: HiDPIError.self) { try f.state.teardown() }
        #expect(throws: HiDPIError.self) { try f.state.restoreOriginalQuietly() }
    }
    try f.state.enableHiDPI(on: originalDisplay, wanted: wantedMode)
    #expect(f.state.physicalModified)
    #expect(f.jobs.count == 1)
    f.runNextJob()
    #expect(!f.state.physicalModified)
    #expect(f.displays.restored.count == 1)
}

@Test func callbacksDuringVirtualStartupWaitForCommit() throws {
    let f = Fixture()
    f.virtual.onStart = {
        f.state.requestDisplayReconciliation()
        #expect(f.jobs.isEmpty)
        #expect(!f.state.virtualActive)
    }
    try f.state.createVirtual(size: (1920, 1080))
    f.runNextJob()
    #expect(f.state.virtualActive)
    #expect(f.virtual.closes == 0)
    try f.state.teardown()
}

@Test func unexpectedDisappearanceRetainsPreferenceAndFailedRestoreForQuit() throws {
    let f = Fixture()
    var errors = 0
    f.state.onRecoveryError = { _ in errors += 1 }
    try f.state.createVirtual(size: (1920, 1080))
    f.displays.online = false
    f.displays.failRestore = true
    f.state.requestDisplayReconciliation()
    f.state.requestDisplayReconciliation()
    #expect(f.jobs.count == 1)
    f.runNextJob()
    #expect(errors == 1)
    #expect(!f.state.virtualActive)
    #expect(f.state.restorationPending)
    #expect(f.savedSize?.0 == 1920)
    f.displays.failRestore = false
    try f.state.teardown()
    #expect(!f.state.restorationPending)
}

@Test func callbackQueuedBeforeAnOperationCannotReconcileInsideItsWait() throws {
    let f = Fixture()
    f.state.requestDisplayReconciliation()
    f.displays.onWait = {
        f.runNextJob()
        #expect(f.displays.restored.isEmpty)
        f.displays.online = false
    }
    try f.state.enableHiDPI(on: originalDisplay, wanted: wantedMode)
    #expect(f.jobs.count == 1)
    f.runNextJob()
    #expect(!f.state.physicalModified)
}

@Test func callbackDuringRestoreIsDeferredAndQuitCancelsPendingRecovery() throws {
    let f = Fixture()
    try f.state.createVirtual(size: (1920, 1080))
    f.displays.onRestore = {
        f.state.requestDisplayReconciliation()
        #expect(f.jobs.isEmpty)
        #expect(throws: HiDPIError.self) { try f.state.removeVirtual() }
    }
    try f.state.teardown()
    #expect(f.jobs.isEmpty)
    #expect(!f.state.restorationPending)
}
