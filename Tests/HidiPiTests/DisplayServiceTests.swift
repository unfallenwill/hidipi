import CoreGraphics
import Foundation
import Testing
import HidiPiCore
@testable import HidiPi

private let sampleMode = ModeInfo(width: 1920, height: 1080,
                                  pixelWidth: 3840, pixelHeight: 2160, hz: 60)

private func display(uuid: String, mirrorOf: UInt32 = 0) -> DisplaySnapshot {
    DisplaySnapshot(id: 2, uuid: uuid, vendor: 1, model: 1, main: true,
                    mirrorOf: mirrorOf, inMirrorSet: false, origin: [0, 0], mode: sampleMode)
}

@Test func waitUntilPropagatesPredicateErrors() {
    #expect(throws: HiDPIError.self) {
        try DisplayService().waitUntil(timeout: 0.1, "timed out") { throw HiDPIError("predicate") }
    }
}

@Test func setModeRejectsUnavailableModes() {
    // No display with this ID exists, so no candidate mode can be found; nothing is
    // switched and no transaction begins.
    #expect(throws: HiDPIError.self) {
        try DisplayService().setMode(99_999, expected: sampleMode)
    }
}

@Test func restoreConnectedSkipsOfflineDisplaysAndRejectsIncompleteMirrorSets() throws {
    let service = DisplayService()
    // Every display offline: logged and skipped, nothing touched.
    try service.restoreConnected(DisplayState(displays: [
        display(uuid: "00000000-0000-0000-0000-000000000001"),
    ]))
    // A live display whose mirror source is offline → refuses before any transaction.
    guard CGMainDisplayID() != 0 else { return }
    let live = try DisplayUUID.string(for: CGMainDisplayID())
    #expect(throws: HiDPIError.self) {
        try service.restoreConnected(DisplayState(displays: [display(uuid: live, mirrorOf: 42)]))
    }
}
