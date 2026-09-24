/// Port of the path section of hidipi/src/hidipi/state.py.
/// Shares ~/.config/hidipi with the Python version; backups and the lock interoperate.
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
