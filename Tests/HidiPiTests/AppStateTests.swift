import CoreGraphics
import Foundation
import Testing
import HidiPiCore
@testable import HidiPi

private let sampleMode = ModeInfo(width: 1920, height: 1080,
                                  pixelWidth: 3840, pixelHeight: 2160, hz: 60)

private func display(inMirrorSet: Bool = false, mode: ModeInfo? = sampleMode) -> DisplaySnapshot {
    DisplaySnapshot(id: 2, uuid: "78589D3B-0A4E-47C1-BF35-FFEA9DABBEB0", vendor: 1, model: 1,
                    main: true, mirrorOf: 0, inMirrorSet: inMirrorSet,
                    origin: [0, 0], mode: mode)
}

@Test func enableHiDPIRejectsMirroredAndModelessTargets() {
    let state = AppState()
    #expect(throws: HiDPIError.self) {
        try state.enableHiDPI(on: display(inMirrorSet: true), wanted: sampleMode)
    }
    #expect(throws: HiDPIError.self) {
        try state.enableHiDPI(on: display(mode: nil), wanted: sampleMode)
    }
}

@Test func guardsEnforceOneModificationAtATime() {
    // A virtual display is active → physical changes are refused.
    let virtual = AppState(virtualController: VirtualDisplayController(service: DisplayService()),
                           virtualSize: (1920, 1080))
    #expect(throws: HiDPIError.self) {
        try virtual.enableHiDPI(on: display(), wanted: sampleMode)
    }
    // Physical changes are unrestored → virtual creation is refused before any CG work.
    let physical = AppState(originalSnapshot: DisplayState(displays: []))
    #expect(throws: HiDPIError.self) {
        try physical.createVirtual(size: (1920, 1080))
    }
}

@Test func removeVirtualKeepsThePreferenceRecordOnTheUnexpectedPath() throws {
    let state = AppState(virtualController: VirtualDisplayController(service: DisplayService()),
                         virtualOriginal: DisplayState(displays: []),
                         virtualSize: (1920, 1080))
    try state.removeVirtual(clearPreference: false)
    #expect(!state.virtualActive)
}

@Test func teardownClosesTheVirtualDisplayAndClearsState() throws {
    let state = AppState(virtualController: VirtualDisplayController(service: DisplayService()),
                         virtualOriginal: DisplayState(displays: []),
                         virtualSize: (1920, 1080))
    try state.teardown()
    #expect(!state.virtualActive)
    #expect(!state.physicalModified)
}
