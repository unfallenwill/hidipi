import Foundation
import Testing
import HidiPiCore
@testable import HidiPi

#if arch(arm64)
@Test func validateOptionsBounds() throws {
    try VirtualDisplayController.validateOptions(size: (1920, 1080), refresh: 60)
    // Equal-pixel portrait is allowed
    try VirtualDisplayController.validateOptions(size: (2160, 3840), refresh: 120)
    #expect(throws: HiDPIError.self) {
        try VirtualDisplayController.validateOptions(size: (1920, 1080), refresh: 200)
    }
    #expect(throws: HiDPIError.self) {
        try VirtualDisplayController.validateOptions(size: (4096, 2160), refresh: 60)
    }
}
#endif

@Test func bridgeCreatesRuntimeObjectsSafely() throws {
    // Object creation only — no display is instantiated until makeDisplay + applySettings.
    #expect(throws: HiDPIError.self) { try VirtualBridge.instantiate("NoSuchClassEver") }
    let descriptor = try VirtualBridge.instantiate("CGVirtualDisplayDescriptor")
    #expect(descriptor.isKind(of: NSObject.self))
    _ = try VirtualBridge.makeMode(width: 1920, height: 1080, refreshRate: 60)
}

@Test func operationLockIsExclusiveUntilReleased() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hidipi-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("operation.lock")

    var first: OperationLock? = try OperationLock(path: path)
    #expect(throws: HiDPIError.self) { _ = try OperationLock(path: path) }
    first = nil   // deinit closes the fd, releasing the flock
    #expect(throws: Never.self) { _ = try OperationLock(path: path) }
}
