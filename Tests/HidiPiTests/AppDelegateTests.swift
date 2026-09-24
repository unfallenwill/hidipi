import AppKit
import CoreGraphics
import Foundation
import Testing
import HidiPiCore
@testable import HidiPi

private let sampleMode = ModeInfo(width: 1920, height: 1080,
                                  pixelWidth: 3840, pixelHeight: 2160, hz: 60)

private func snapshot(id: UInt32 = 2, inMirrorSet: Bool = false,
                      mode: ModeInfo? = sampleMode) -> DisplaySnapshot {
    DisplaySnapshot(id: id, uuid: "78589D3B-0A4E-47C1-BF35-FFEA9DABBEB0", vendor: 1, model: 1,
                    main: true, mirrorOf: 0, inMirrorSet: inMirrorSet,
                    origin: [0, 0], mode: mode)
}

/// Records dialog presentations instead of showing real NSAlerts.
private final class RecordingDialogs {
    var alerts: [String] = []
    var confirmResult = false
    var confirmAsked = false

    func install(on delegate: AppDelegate) {
        var dialogs = DialogPresenter()
        let recorder = self
        dialogs.alert = { title, _ in recorder.alerts.append(title) }
        dialogs.confirm = { _, _, _, _ in recorder.confirmAsked = true; return recorder.confirmResult }
        delegate.dialogs = dialogs
    }
}

/// Blocks until the main queue has drained everything queued before the call.
private func waitForMainQueue() {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { done.signal() }
    _ = done.wait(timeout: .now() + 2)
}

@Test func quitIsApprovedImmediatelyOnCleanState() {
    let delegate = AppDelegate(state: AppState())
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
}

@Test func quitWithFailingRestoreAsksAndObeysConfirmation() throws {
    guard CGMainDisplayID() != 0 else { return }
    let uuid = try DisplayUUID.string(for: CGMainDisplayID())
    // A snapshot whose mirror source is offline makes teardown throw without any
    // display transaction.
    let liveButIncomplete = DisplaySnapshot(id: CGMainDisplayID(), uuid: uuid, vendor: 1, model: 1,
                                            main: true, mirrorOf: 42, inMirrorSet: false,
                                            origin: [0, 0], mode: sampleMode)
    let state = AppState(originalSnapshot: DisplayState(displays: [liveButIncomplete]))
    let delegate = AppDelegate(state: state)
    let recorder = RecordingDialogs()
    recorder.install(on: delegate)

    recorder.confirmResult = false
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
    #expect(recorder.confirmAsked)

    recorder.confirmResult = true
    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
}

@Test func runRecordsFailuresAndIgnoresNoOps() {
    let delegate = AppDelegate(state: AppState())
    let recorder = RecordingDialogs()
    recorder.install(on: delegate)

    delegate.run(.enableHiDPI(display: snapshot(inMirrorSet: true), wanted: sampleMode))
    #expect(recorder.alerts == ["Operation Failed"])

    delegate.run(.createVirtual(size: (5000, 100)))   // validateOptions rejects the size
    #expect(recorder.alerts.count == 2)

    delegate.run(.removeVirtual)                       // no-op on a clean state
    #expect(recorder.alerts.count == 2)
}

@Test func reconfigurationCallbackCleansUpVanishedStates() {
    // Physical: the modified display is gone → quiet restore and state cleared.
    let physical = AppDelegate(state: AppState(originalSnapshot: DisplayState(displays: []),
                                               modifiedDisplayID: 99_999))
    physical.onDisplayReconfiguration()
    physical.onDisplayReconfiguration()   // second call coalesces while one is pending
    waitForMainQueue()
    #expect(!physical.state.physicalModified)

    // Virtual: the controller's display is gone → cleanup, preference record kept.
    let virtual = AppDelegate(state: AppState(
        virtualController: VirtualDisplayController(service: DisplayService()),
        virtualOriginal: DisplayState(displays: []), virtualSize: (1920, 1080)))
    virtual.onDisplayReconfiguration()
    waitForMainQueue()
    #expect(!virtual.state.virtualActive)
    if let size = VirtualPreference.load() {   // record untouched by the unexpected path
        #expect((640...7680).contains(size.0))
    }
}
