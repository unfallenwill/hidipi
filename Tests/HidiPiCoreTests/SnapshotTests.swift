import Foundation
import Testing
@testable import HidiPiCore

func makeState(displays: [DisplaySnapshot]? = nil,
               id: UInt32 = 2, uuid: String = "78589D3B-0A4E-47C1-BF35-FFEA9DABBEB0",
               origin: [Int] = [0, 0], mirrorOf: UInt32 = 0,
               mode: ModeInfo? = ModeInfo(width: 2560, height: 1440, pixelWidth: 2560,
                                          pixelHeight: 1440, hz: 60, modeID: 82)) -> DisplayState {
    let display = DisplaySnapshot(id: id, uuid: uuid, vendor: 1552, model: 40984,
                                  main: true, mirrorOf: mirrorOf, inMirrorSet: false,
                                  origin: origin, mode: mode)
    return DisplayState(displays: displays ?? [display])
}

@Test func validateAcceptsRegularAndEmpty() {
    #expect(throws: Never.self) { try makeState().validate() }
    // Empty = headless capture (no stable displays) — valid
    #expect(throws: Never.self) { try DisplayState(displays: []).validate() }
}

@Test func validateRejections() {
    #expect(throws: HiDPIError.self) { try makeState(id: 0).validate() }                  // id=0
    let two = makeState(displays: [
        DisplaySnapshot(id: 2, uuid: "78589D3B-0A4E-47C1-BF35-FFEA9DABBEB0", vendor: 1, model: 1,
                        main: true, mirrorOf: 0, inMirrorSet: false,
                        origin: [0, 0], mode: ModeInfo(width: 1, height: 1, pixelWidth: 2, pixelHeight: 2, hz: 60)),
        DisplaySnapshot(id: 2, uuid: "00000000-0000-0000-0000-000000000001", vendor: 1, model: 1,
                        main: false, mirrorOf: 0, inMirrorSet: false,
                        origin: [0, 0], mode: ModeInfo(width: 1, height: 1, pixelWidth: 2, pixelHeight: 2, hz: 60))])
    #expect(throws: HiDPIError.self) { try two.validate() }                               // duplicate id
    #expect(throws: HiDPIError.self) { try makeState(uuid: "not-a-uuid").validate() }
    #expect(throws: HiDPIError.self) { try makeState(origin: [0, 1, 2]).validate() }
    #expect(throws: HiDPIError.self) { try makeState(origin: [0, 1 << 31]).validate() }
    #expect(throws: HiDPIError.self) { try makeState(mode: nil).validate() }
    #expect(throws: HiDPIError.self) {
        try makeState(mode: ModeInfo(width: 65537, height: 1, pixelWidth: 2, pixelHeight: 2, hz: 60)).validate()
    }
    #expect(throws: HiDPIError.self) {
        try makeState(mode: ModeInfo(width: 1, height: 1, pixelWidth: 2, pixelHeight: 2, hz: 1000.5)).validate()
    }
    #expect(throws: HiDPIError.self) { try makeState(mirrorOf: 2).validate() }            // self-mirror
    #expect(throws: HiDPIError.self) { try makeState(mirrorOf: 9).validate() }            // missing target
}
