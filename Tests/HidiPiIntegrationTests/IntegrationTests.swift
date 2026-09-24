// Integration tests execute real CoreGraphics transactions (mode switches, virtual
// display creation) against the live desktop of whatever machine runs them. They are
// only safe on disposable machines such as CI macOS runners, and are therefore gated
// behind HIDIPI_INTEGRATION=1: a plain local `swift test` skips every test here.
//
// The flows under test restore their own state: mode switches use the app-only scope
// and are followed by an explicit restore; virtual displays are closed before exit.
import AppKit
import CoreGraphics
import Foundation
import Testing
import HidiPiCore
@testable import HidiPi

private let integrationEnabled = ProcessInfo.processInfo.environment["HIDIPI_INTEGRATION"] == "1"

/// Serialized because CG configuration transactions must not overlap: parallel tests
/// racing setMode/virtual-display creation segfault inside CoreGraphics.
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

    /// The full virtual display lifecycle: objc bridge → start (apply mode, wait for
    /// online, verify HiDPI) → close (teardown, wait for offline). The CGVirtualDisplay
    /// bridge needs a GUI process running the work on its main thread — exactly the
    /// context the app provides via NSApplication.run — so the test replicates it:
    /// bootstrap NSApplication and hop to the main thread.
    @Test func virtualDisplayLifecycle() throws {
        let service = DisplayService()
        var online = false
        try DispatchQueue.main.sync {
            // NSApplication must only be touched on the main thread.
            NSApplication.shared.setActivationPolicy(.accessory)
            let controller = VirtualDisplayController(service: service)
            let id = try controller.start(size: (1920, 1080), refresh: 60)
            online = DisplayIO.isOnline(id)
            let expected = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840,
                                    pixelHeight: 2160, hz: 60)
            #expect(Modes.modeMatchesLenient(DisplayIO.currentMode(id), expected))
            controller.close()
        }
        #expect(online)
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
}
