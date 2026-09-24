import Testing
@testable import HidiPiCore

private let uuidA = "78589D3B-0A4E-47C1-BF35-FFEA9DABBEB0"

private func saved(uuid: String = uuidA, mode: ModeInfo?) -> DisplaySnapshot {
    DisplaySnapshot(id: 2, uuid: uuid, vendor: 1, model: 1, main: true,
                    mirrorOf: 0, inMirrorSet: false, origin: [0, 0], mode: mode)
}

@Test func plannerResolvesByUUIDAndPrefersMatchingModeID() throws {
    let wanted = ModeInfo(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440,
                          hz: 60, modeID: 82)
    let m82 = ModeInfo(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440,
                       hz: 60, modeID: 82)
    let m90 = ModeInfo(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440,
                       hz: 60, modeID: 90)
    let entries = try RestorePlanner.plan(DisplayState(displays: [saved(mode: wanted)]),
                                          online: [uuidA: 7]) { _ in [m90, m82] }
    #expect(entries.count == 1)
    #expect(entries[0].display == 7)
    #expect(entries[0].mode.modeID == 82)   // mode_id tie-break prefers the matching one
    #expect(entries[0].target.uuid == uuidA)
}

@Test func plannerRejectsUnresolvableStates() {
    // Display not online
    #expect(throws: HiDPIError.self) {
        try RestorePlanner.plan(DisplayState(displays: [saved(mode: nil)]),
                                online: [:]) { _ in [] }
    }
    // Missing original mode
    #expect(throws: HiDPIError.self) {
        try RestorePlanner.plan(DisplayState(displays: [saved(mode: nil)]),
                                online: [uuidA: 7]) { _ in [] }
    }
    // No live mode matches the wanted one
    let wanted = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160,
                          hz: 60, modeID: 1)
    #expect(throws: HiDPIError.self) {
        try RestorePlanner.plan(DisplayState(displays: [saved(mode: wanted)]),
                                online: [uuidA: 7]) {
            _ in [ModeInfo(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, hz: 60)]
        }
    }
}
