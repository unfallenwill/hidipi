import Foundation
import HidiPiCore

/// The system boundary used by operation flows. Tests can fail individual steps without
/// touching the desktop, including verification waits and rollback.
protocol DisplayServicing {
    func snapshot(allowEmpty: Bool) throws -> DisplayState
    func setMode(_ display: UInt32, expected: ModeInfo) throws
    func restoreConnected(_ state: DisplayState) throws
    func waitUntil(timeout: TimeInterval, _ error: String, _ predicate: () throws -> Bool) throws
    func currentMode(_ display: UInt32) -> ModeInfo?
    func isOnline(_ display: UInt32) -> Bool
    func allModes(_ display: UInt32) -> [ModeInfo]
}

extension DisplayServicing {
    func snapshot() throws -> DisplayState { try snapshot(allowEmpty: false) }
}

extension DisplayService: DisplayServicing {
    func currentMode(_ display: UInt32) -> ModeInfo? { DisplayIO.currentMode(display) }
    func isOnline(_ display: UInt32) -> Bool { DisplayIO.isOnline(display) }
    func allModes(_ display: UInt32) -> [ModeInfo] { DisplayIO.allModes(display).map(DisplayIO.info) }
}

protocol VirtualDisplayControlling: AnyObject {
    var displayID: UInt32 { get }
    func start(size: (Int, Int), refresh: Double) throws -> UInt32
    func close()
}

extension VirtualDisplayController: VirtualDisplayControlling {}

struct VirtualPreferenceStore {
    var load: () -> (Int, Int)? = { VirtualPreference.load() }
    var save: ((Int, Int)) throws -> Void = { try VirtualPreference.save($0) }
    var clear: () -> Void = { VirtualPreference.clear() }
}
