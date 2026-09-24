/// 移植 hidipi/src/hidipi/state.py 的路径部分。
/// 与 Python 版共用 ~/.config/hidipi，备份与锁互操作。
import Foundation

public enum Paths {
    public static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hidipi", isDirectory: true)
    }

    public static var backupDir: URL {
        configDir.appendingPathComponent("backups", isDirectory: true)
    }

    public static var operationLock: URL {
        configDir.appendingPathComponent("operation.lock")
    }
}
