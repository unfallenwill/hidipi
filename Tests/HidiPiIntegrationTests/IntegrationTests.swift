// Integration tests execute real CoreGraphics transactions (mode switches against the
// live desktop) on disposable machines such as CI macOS runners. They are gated behind
// HIDIPI_INTEGRATION=1: a plain local `swift test` skips every test here.
//
// The flows under test restore their own state: mode switches use the app-only scope
// and are followed by an explicit restore.
//
// Deliberately NOT covered here: the full virtual display lifecycle. CGVirtualDisplay
// creation cannot run in test processes — locally (a real desktop) the private-class
// instantiation segfaults inside the test runner, and on CI runners the object is
// created but the display never comes online (the VM's display pipeline is itself
// software). Virtual display creation stays covered by the object-level bridge test in
// HidiPiTests and by real usage of the app.
import CoreGraphics
import Foundation
import Testing
import HidiPiCore
@testable import HidiPi

private let integrationEnabled = ProcessInfo.processInfo.environment["HIDIPI_INTEGRATION"] == "1"

/// Serialized because CG configuration transactions must not overlap: parallel tests
/// racing setMode segfault inside CoreGraphics.
@Suite(.enabled(if: integrationEnabled), .serialized)
struct IntegrationTests {
    @Test func snapshotCapturesTheLiveDesktop() throws {
        let state = try DisplayService().snapshot()
        #expect(!state.displays.isEmpty)
        #expect(state.displays.allSatisfy { !$0.uuid.isEmpty && $0.mode != nil })
    }

    /// Re-applies the current mode: exercises the full set_mode transaction and the
    /// restore verification without any visible change, so it works even on
    /// single-mode virtual displays.
    @Test func setModeTransactionAndRestoreRoundTrip() throws {
        let service = DisplayService()
        let original = try service.snapshot()
        guard let display = original.displays.first, let current = display.mode else { return }
        try service.setMode(display.id, expected: current)
        try service.waitUntil(timeout: 5, "the re-applied mode did not verify") {
            Modes.modeMatches(DisplayIO.currentMode(display.id), current)
        }
        try service.restore(original)   // restores and verifies internally
        #expect(Modes.modeMatches(DisplayIO.currentMode(display.id), current))
    }

    /// Switches to a genuinely different mode when one exists (skipped otherwise),
    /// then restores — the full physical-switch flow the menu drives.
    @Test func switchToADifferentModeAndBack() throws {
        let service = DisplayService()
        let original = try service.snapshot()
        guard let display = original.displays.first, let current = display.mode else { return }
        let other = DisplayIO.allModes(display.id).map(DisplayIO.info).first {
            $0.usable && !Modes.modeMatches($0, current)
        }
        guard let other else { return }   // single-mode display: nothing to switch to
        try service.setMode(display.id, expected: other)
        try service.waitUntil(timeout: 5, "the switched mode did not verify") {
            Modes.modeMatches(DisplayIO.currentMode(display.id), other)
        }
        try service.restore(original)
        #expect(Modes.modeMatches(DisplayIO.currentMode(display.id), current))
    }

    /// enableHiDPI with the current mode takes the already-there early return, and
    /// teardown on an unmodified state is a clean no-op.
    @Test func enableHiDPIWithCurrentModeIsANoOp() throws {
        let state = AppState()
        let snapshot = try state.service.snapshot()
        guard let display = snapshot.displays.first, let current = display.mode else { return }
        try state.enableHiDPI(on: display, wanted: current)
        #expect(!state.physicalModified)
        try state.teardown()
    }

    /// The full flow the menu drives: a real switch to a different mode (via
    /// hidpiOptions when one exists, otherwise re-applying the current mode), then
    /// teardown restoring the original state.
    @Test func enableHiDPIFullFlowRestoresOnTeardown() throws {
        let state = AppState()
        let snapshot = try state.service.snapshot()
        guard let display = snapshot.displays.first(where: { $0.vendor != VirtualBridge.vendorID }),
              let current = display.mode else { return }
        let wanted = AppState.hidpiOptions(for: display).first?.mode ?? current
        try state.enableHiDPI(on: display, wanted: wanted)
        if !Modes.modeMatches(current, wanted) {
            #expect(state.physicalModified)
        }
        try state.teardown()
        #expect(!state.physicalModified)
        #expect(Modes.modeMatches(DisplayIO.currentMode(display.id), current))
    }

    /// createVirtual either succeeds or is refused by the environment (CI runners never
    /// bring the display online); either way the app must be left in a clean state.
    @Test func createVirtualAttemptLeavesCleanState() throws {
        let state = AppState()
        do {
            try state.createVirtual(size: (1920, 1080))
            #expect(state.virtualActive)
        } catch {
            #expect(!state.virtualActive)   // rolled back
        }
        try state.teardown()
        #expect(!state.virtualActive)
        try state.teardown()   // idempotent
    }
}
