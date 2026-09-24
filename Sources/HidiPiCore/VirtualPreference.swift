/// 虚拟屏的"期望状态"记录（~/.config/hidipi/virtual.json）。
/// 创建成功即记下尺寸；登录自启动后据此自动重建；显式移除才清除。
/// 与 Python 版的 autostart.json 各自独立，互不干扰。
import Foundation

public enum VirtualPreference {
    public static var url: URL {
        Paths.configDir.appendingPathComponent("virtual.json")
    }

    /// 读取期望尺寸；缺失或非法时返回 nil。
    public static func load(from file: URL = url) -> (Int, Int)? {
        guard let data = try? Data(contentsOf: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let size = object["size"] as? [Int], size.count == 2,
              640...7680 ~= size[0], 480...4320 ~= size[1] else { return nil }
        return (size[0], size[1])
    }

    /// 原子写入期望尺寸（目录已由锁创建，权限 0600）。
    public static func save(_ size: (Int, Int), to file: URL = url) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["size": [size.0, size.1]],
                                                 options: [.prettyPrinted, .sortedKeys])
        try payload.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// 清除期望状态（用户显式移除虚拟屏时调用）。
    public static func clear(at file: URL = url) {
        try? FileManager.default.removeItem(at: file)
    }
}
