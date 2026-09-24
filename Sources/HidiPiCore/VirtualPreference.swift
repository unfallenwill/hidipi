/// The virtual display's "desired state" record (~/.config/hidipi/virtual.json).
/// The size is recorded on successful creation; login-autostart rebuilds from it;
/// only an explicit removal clears it.
/// Independent of the Python version's autostart.json; the two never interfere.
import Foundation

public enum VirtualPreference {
    public static var url: URL {
        Paths.configDir.appendingPathComponent("virtual.json")
    }

    /// Load the desired size; nil when missing or invalid.
    public static func load(from file: URL = url) -> (Int, Int)? {
        guard let data = try? Data(contentsOf: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let size = object["size"] as? [Int], size.count == 2,
              640...7680 ~= size[0], 480...4320 ~= size[1] else { return nil }
        return (size[0], size[1])
    }

    /// Atomically write the desired size (directory already exists with the lock; mode 0600).
    public static func save(_ size: (Int, Int), to file: URL = url) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["size": [size.0, size.1]],
                                                 options: [.prettyPrinted, .sortedKeys])
        try payload.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Clear the desired state (called when the user explicitly removes the virtual display).
    public static func clear(at file: URL = url) {
        try? FileManager.default.removeItem(at: file)
    }
}
