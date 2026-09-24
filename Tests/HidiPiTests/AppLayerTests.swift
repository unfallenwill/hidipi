import CoreGraphics
import Foundation
import Testing
import HidiPiCore
@testable import HidiPi

@Test func checkMapsCGErrors() {
    #expect(throws: Never.self) { try DisplayIO.check(.success, "probing") }
    #expect(throws: HiDPIError.self) { try DisplayIO.check(.failure, "probing") }
}

@Test func waitUntilReturnsImmediatelyOrTimesOut() throws {
    let service = DisplayService()
    try service.waitUntil(timeout: 5, "never happens") { true }
    #expect(throws: HiDPIError.self) {
        try service.waitUntil(timeout: 0.2, "timed out") { false }
    }
}

@Test func isOnlineRejectsUnknownDisplay() {
    #expect(!DisplayIO.isOnline(0))
}

@Test func hidpiOptionsIsEmptyWhenTheDisplayHasNoModes() {
    // A display ID that cannot exist exercises the CG-enumeration path returning empty.
    let display = DisplaySnapshot(id: 99_999, uuid: "78589D3B-0A4E-47C1-BF35-FFEA9DABBEB0",
                                  vendor: 1, model: 1, main: true, mirrorOf: 0, inMirrorSet: false,
                                  origin: [0, 0],
                                  mode: ModeInfo(width: 1920, height: 1080,
                                                 pixelWidth: 1920, pixelHeight: 1080, hz: 60))
    #expect(AppState.hidpiOptions(for: display).isEmpty)
}

@Test func mainDisplayUUIDResolves() throws {
    let main = CGMainDisplayID()
    guard main != 0 else { return }   // no WindowServer in this environment
    let uuid = try DisplayUUID.string(for: main)
    #expect(UUID(uuidString: uuid) != nil)
}

@Test func loginItemStatusReadsSMAppService() {
    // Reads the real registration state; must not throw or crash.
    _ = LoginItem.isEnabled
}
