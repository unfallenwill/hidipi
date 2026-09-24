/// Port of runtime.file_lock / single_instance: an exclusive flock, mutual with the Python
/// version. Held for the app's lifetime; if the Python version is running (enable --keep /
/// the autostart background process), startup is refused.
import Foundation
import HidiPiCore

/// Darwin's flock function clashes with the struct of the same name; bind the C symbol directly.
/// Must be flock (not fcntl/F_SETLK): the lock semantics match Python's fcntl.flock, which is
/// what makes them mutually exclusive.
@_silgen_name("flock")
private func c_flock(_ fd: Int32, _ operation: Int32) -> Int32

final class OperationLock {
    private let fd: Int32

    /// A thrown error means the lock is held (another HiDPI operation is running).
    init(filename: String) throws {
        let directory = Paths.configDir
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(filename)
        let descriptor = Darwin.open(path.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw HiDPIError("Cannot open lock file: \(path.path)")
        }
        guard c_flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw HiDPIError("Another HiDPI operation is running. Press Ctrl+C in its terminal, "
                + "or run hidipi autostart uninstall, then start this app.")
        }
        fd = descriptor
    }

    deinit { Darwin.close(fd) }   // closing releases the flock
}
