/// Path constants for ~/.config/hidipi, shared with the Python version; the operation
/// lock interoperates with it.
import Foundation

public enum Paths {
    public static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hidipi", isDirectory: true)
    }

    public static var operationLock: URL {
        configDir.appendingPathComponent("operation.lock")
    }
}
