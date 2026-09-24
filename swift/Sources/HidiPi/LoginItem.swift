/// 登录自启：SMAppService.mainApp（macOS 13+ 公开接口）。
import Foundation
import HidiPiCore
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw HiDPIError("设置登录启动失败：\(error.localizedDescription)")
        }
    }
}
