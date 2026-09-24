import Foundation
import Testing
@testable import HidiPiCore

// 与 Python 真实输出（2 空格缩进、同字段集）一致的 schema 1 样本。
let schema1JSON = """
{
  "schema": 1,
  "created": "2026-09-22T16:40:20.123456+08:00",
  "macos": "27.0",
  "displays": [
    {
      "id": 2,
      "uuid": "78589D3B-0A4E-47C1-BF35-FFEA9DABBEB0",
      "vendor": 1552,
      "model": 40984,
      "serial": 3,
      "builtin": false,
      "main": true,
      "mirror_of": 0,
      "in_mirror_set": false,
      "origin": [
        0,
        0
      ],
      "millimeters": [
        597.0,
        336.0
      ],
      "mode": {
        "width": 2560,
        "height": 1440,
        "pixel_width": 2560,
        "pixel_height": 1440,
        "hz": 60,
        "mode_id": 82,
        "flags": 7,
        "usable": true
      }
    }
  ]
}
"""

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
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(displays: [])) }   // 空列表
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
    #expect(throws: HiDPIError.self) { try Backup.validate(two) }                          // id 重复
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
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(mirrorOf: 2)) }    // 指向自己
    #expect(throws: HiDPIError.self) { try Backup.validate(makeSnapshot(mirrorOf: 9)) }    // 不存在的屏
}

@Test func schema1RoundTripAndHzIntDecode() throws {
    let snapshot = try Backup.decode(schema1JSON.data(using: .utf8)!)
    #expect(snapshot.displays.count == 1)
    #expect(snapshot.displays[0].mode?.hz == 60)                 // JSON int → Double
    #expect(snapshot.displays[0].mode?.modeID == 82)
    let again = try Backup.decode(try Backup.encoder.encode(snapshot))
    #expect(again == snapshot)
}

@Test func pythonFixtureInterop() throws {
    // 兼容不同构建系统下 .copy 资源的落点（带或不带 Fixtures 子目录）。
    guard let url = Bundle.module.url(forResource: "python-backup", withExtension: "json",
                                      subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: "python-backup", withExtension: "json") else {
        Issue.record("找不到 python-backup.json 测试资源")
        return
    }
    let snapshot = try Backup.decode(try Data(contentsOf: url))
    #expect(snapshot.schema == 2)
    #expect(snapshot.headless == true)
    #expect(snapshot.displays.isEmpty)
    #expect(snapshot.systemFallback?.count == 1)
    #expect(snapshot.systemFallback?.first?.vendor == 0x756E6B6E)   // 瞬态屏
}

@Test func rejectsNaNHz() {
    let nan = schema1JSON.replacingOccurrences(of: "\"hz\": 60", with: "\"hz\": NaN")
    #expect(throws: (any Error).self) { try Backup.decode(nan.data(using: .utf8)!) }
}

@Test func writeIsAtomicAndVerifiable() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hidipi-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let snapshot = makeSnapshot()
    let path = try Backup.write(snapshot, to: dir)
    #expect(path.lastPathComponent.range(of: #"^display-\d{8}-\d{6}-[0-9a-f]{8}\.json$"#,
                                         options: .regularExpression) != nil)
    #expect(try Backup.decode(try Data(contentsOf: path)) == snapshot)
    // 写入不影响已有备份
    let second = try Backup.write(makeSnapshot(id: 3,
        uuid: "00000000-0000-0000-0000-000000000001"), to: dir)
    #expect(FileManager.default.fileExists(atPath: path.path))
    #expect(path != second)
}
