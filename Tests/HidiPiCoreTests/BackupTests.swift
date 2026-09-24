import Foundation
import Testing
@testable import HidiPiCore

func makeSnapshot(schema: Int = 1, displays: [DisplaySnapshot]? = nil,
                  id: UInt32 = 2, uuid: String = "78589D3B-0A4E-47C1-BF35-FFEA9DABBEB0",
                  origin: [Int] = [0, 0], mirrorOf: UInt32 = 0,
                  mode: ModeInfo? = ModeInfo(width: 2560, height: 1440, pixelWidth: 2560,
                                             pixelHeight: 1440, hz: 60, modeID: 82, flags: 7)) -> BackupSnapshot {
    let display = DisplaySnapshot(id: id, uuid: uuid, vendor: 1552, model: 40984, serial: 3,
                                  builtin: false, main: true, mirrorOf: mirrorOf, inMirrorSet: false,
                                  origin: origin, millimeters: [597, 336], mode: mode)
    var snapshot = BackupSnapshot(created: Backup.timestamp(), macos: "27.0",
                                  displays: displays ?? [display])
    snapshot.schema = schema
    return snapshot
}

@Test func validateAcceptsSchema1And2() {
    #expect(throws: Never.self) { try Backup.validate(makeSnapshot()) }
    #expect(throws: Never.self) {
        try Backup.validate(BackupSnapshot(headlessCreated: Backup.timestamp(),
                                           macos: "27.0", systemFallback: nil))
    }
}

@Test func validateRejections() {
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(schema: 3)) }
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(displays: [])) }   // empty list
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(id: 0)) }          // id=0
    let two = makeSnapshot(displays: [
        DisplaySnapshot(id: 2, uuid: "78589D3B-0A4E-47C1-BF35-FFEA9DABBEB0", vendor: 1, model: 1,
                        serial: 1, builtin: false, main: true, mirrorOf: 0, inMirrorSet: false,
                        origin: [0, 0], millimeters: [1, 1],
                        mode: ModeInfo(width: 1, height: 1, pixelWidth: 2, pixelHeight: 2, hz: 60)),
        DisplaySnapshot(id: 2, uuid: "00000000-0000-0000-0000-000000000001", vendor: 1, model: 1,
                        serial: 1, builtin: false, main: false, mirrorOf: 0, inMirrorSet: false,
                        origin: [0, 0], millimeters: [1, 1],
                        mode: ModeInfo(width: 1, height: 1, pixelWidth: 2, pixelHeight: 2, hz: 60))])
    #expect(throws: HiDPIError.self) { try Backup.validate(two) }                          // duplicate id
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(uuid: "not-a-uuid")) }
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(origin: [0, 1, 2])) }
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(origin: [0, 1 << 31])) }
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(mode: nil)) }
    #expect(throws: HiDPIError.self) {
        try Backup.validate(makeSnapshot(
            mode: ModeInfo(width: 65537, height: 1, pixelWidth: 2, pixelHeight: 2, hz: 60)))
    }
    #expect(throws: HiDPIError.self) {
        try Backup.validate(makeSnapshot(
            mode: ModeInfo(width: 1, height: 1, pixelWidth: 2, pixelHeight: 2, hz: 1000.5)))
    }
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(mirrorOf: 2)) }    // self-mirror
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(mirrorOf: 9)) }    // missing target
}
