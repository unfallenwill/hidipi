import Testing
@testable import HidiPiCore

@Test func pathsShareTheConfigDirectory() {
    #expect(Paths.configDir.path.hasSuffix(".config/hidipi"))
    #expect(Paths.operationLock.lastPathComponent == "operation.lock")
    #expect(Paths.operationLock.deletingLastPathComponent() == Paths.configDir)
}
