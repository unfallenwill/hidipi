import Foundation
import Testing
@testable import HidiPiCore

@Test func virtualPreferenceRoundTrip() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("virtual-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(VirtualPreference.load(from: file) == nil)          // 缺失 → nil

    try VirtualPreference.save((1920, 1080), to: file)
    #expect(VirtualPreference.load(from: file) == nil || VirtualPreference.load(from: file)! == (1920, 1080))
    #expect(VirtualPreference.load(from: file)!.0 == 1920)

    VirtualPreference.clear(at: file)
    #expect(VirtualPreference.load(from: file) == nil)          // 清除 → nil
}

@Test func virtualPreferenceRejectsInvalid() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("virtual-invalid-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("virtual.json")

    try #"{"size": [100, 1080]}"#.data(using: .utf8)!.write(to: file)   // 宽越界
    #expect(VirtualPreference.load(from: file) == nil)
    try #"{"size": [1920]}"#.data(using: .utf8)!.write(to: file)        // 只有宽
    #expect(VirtualPreference.load(from: file) == nil)
    try #"not json"#.data(using: .utf8)!.write(to: file)
    #expect(VirtualPreference.load(from: file) == nil)
}
