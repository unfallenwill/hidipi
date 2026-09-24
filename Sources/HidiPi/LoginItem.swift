/// Launch at login: SMAppService.mainApp (the public macOS 13+ API).
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
            throw HiDPIError("Failed to configure launch at login: \(error.localizedDescription)")
        }
    }
}
