/// 移植 runtime.file_lock / single_instance：flock 独占锁，与 Python 版互斥。
/// App 生命周期内持有；Python 版（enable --keep / autostart 后台进程）在跑时拒绝启动。
import Foundation
import HidiPiCore

/// Darwin 里 flock 函数与同名 struct 冲突，直接绑 C 符号。
/// 必须用 flock（而非 fcntl/F_SETLK）：锁语义与 Python fcntl.flock 一致，才能互斥。
@_silgen_name("flock")
private func c_flock(_ fd: Int32, _ operation: Int32) -> Int32

final class OperationLock {
    private let fd: Int32

    /// 抛错即说明锁被占用（另一个 HiDPI 操作正在运行）。
    init(filename: String) throws {
        let directory = Paths.configDir
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(filename)
        let descriptor = Darwin.open(path.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw HiDPIError("无法打开锁文件：\(path.path)")
        }
        guard c_flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw HiDPIError("另一个 HiDPI 操作正在运行。请先在其终端按 Ctrl+C，或执行 "
                + "hidipi autostart uninstall，再启动本应用。")
        }
        fd = descriptor
    }

    deinit { Darwin.close(fd) }   // 关闭即释放 flock
}
