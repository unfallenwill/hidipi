/// 应用状态与全部操作流程（enable / virtual / restore / quit）。
/// 遵循 Python 版语义：同一时刻只有一种修改（物理屏或虚拟屏其一），
/// 退出或移除时按备份恢复。所有方法必须在主线程调用。
import Foundation
import HidiPiCore
import CoreGraphics

final class AppState {
    let service = DisplayService()
    private(set) var lock: OperationLock?

    // —— 物理屏修改状态 ——
    private(set) var originalSnapshot: BackupSnapshot?   // 首次修改前的完整快照
    private(set) var modifiedDisplayID: CGDirectDisplayID?
    private(set) var modifiedUUID: String?
    private(set) var backupURL: URL?

    // —— 虚拟屏状态 ——
    private(set) var virtualController: VirtualDisplayController?
    private(set) var virtualOriginal: BackupSnapshot?
    private(set) var virtualBackupURL: URL?
    private(set) var virtualSize: (Int, Int)?

    var physicalModified: Bool { originalSnapshot != nil }
    var virtualActive: Bool { virtualController != nil }

    /// 启动时获取与 Python 版互斥的操作锁。
    func acquireLock() throws {
        lock = try OperationLock(filename: "operation.lock")
    }

    // MARK: - 物理屏 HiDPI（移植 display.enable_hidpi，去掉预览环节）

    /// target 来自刚刷新的快照；wanted 为菜单选择的 HiDPI 模式。
    func enableHiDPI(on target: DisplaySnapshot, wanted: ModeInfo) throws {
        guard !target.inMirrorSet else {
            throw HiDPIError("目标显示器正在镜像。请先在系统设置中解除镜像，再切换 HiDPI。")
        }
        guard let current = target.mode else {
            throw HiDPIError("无法读取原始模式，不能安全备份；取消操作。")
        }
        if Modes.modeMatches(current, wanted) { return }   // 已处于该模式
        let original = try service.snapshot()
        // 备份并回读核验 —— 任何显示器改动之前完成。
        let backup = try Backup.write(original, to: Paths.backupDir)
        NSLog("hidipi: 已备份并回读核验：%@", backup.path)
        if originalSnapshot == nil {
            originalSnapshot = original
            backupURL = backup
        }
        modifiedDisplayID = target.id
        modifiedUUID = target.uuid
        do {
            try service.setMode(target.id, expected: wanted)
            try service.waitUntil(timeout: 5, "系统未切换到指定 HiDPI 模式，正在恢复") {
                Modes.modeMatches(DisplayIO.currentMode(target.id), wanted)
            }
        } catch {
            try? restoreOriginalQuietly()
            throw error
        }
    }

    // MARK: - 虚拟屏（移植 virtual.run）

    func createVirtual(size: (Int, Int)) throws {
        try VirtualDisplayController.validateOptions(size: size, refresh: 60)
        let original = try VirtualDisplay.captureOriginal(service)
        let backup = try Backup.write(original, to: Paths.backupDir)
        NSLog("hidipi: 创建虚拟屏幕前已备份：%@", backup.path)
        let controller = VirtualDisplayController(service: service)
        do {
            let id = try controller.start(size: size, refresh: 60)
            NSLog("hidipi: 虚拟屏幕已核验，ID=%u", id)
            virtualController = controller
            virtualOriginal = original
            virtualBackupURL = backup
            virtualSize = size
        } catch {
            controller.close()
            try? service.restoreConnected(original)
            throw error
        }
    }

    func removeVirtual() throws {
        guard let controller = virtualController else { return }
        virtualController = nil
        controller.close()
        let original = virtualOriginal
        virtualOriginal = nil
        virtualBackupURL = nil
        virtualSize = nil
        if let original {
            try service.restoreConnected(original)   // 失败上抛：备份仍在磁盘
        }
    }

    // MARK: - 从备份恢复（移植 cli 的 restore 分支）

    func restore(from url: URL) throws {
        let saved = try Backup.decode(try Data(contentsOf: url))
        let currentBackup = try Backup.write(try service.snapshot(), to: Paths.backupDir)
        NSLog("hidipi: 恢复前的状态也已备份：%@", currentBackup.path)
        try service.restore(saved)
        // 恢复成功后，本应用不再持有"已修改"状态。
        originalSnapshot = nil
        modifiedDisplayID = nil
        modifiedUUID = nil
        backupURL = nil
    }

    // MARK: - 退出清理（对应 Python 的 finally 恢复）

    /// 尽力恢复且不抛错（用于回调里的安全兜底）。
    func restoreOriginalQuietly() throws {
        if let original = originalSnapshot {
            try service.restoreConnected(original)
        }
        originalSnapshot = nil
        modifiedDisplayID = nil
        modifiedUUID = nil
        backupURL = nil
    }

    /// 退出前的完整清理；失败时调用方决定是否仍退出（磁盘备份仍在）。
    func teardown() throws {
        if let controller = virtualController {
            virtualController = nil
            controller.close()
            if let original = virtualOriginal {
                try service.restoreConnected(original)
            }
            virtualOriginal = nil
            virtualBackupURL = nil
            virtualSize = nil
        }
        if let original = originalSnapshot {
            try service.restoreConnected(original)
            originalSnapshot = nil
            modifiedDisplayID = nil
            modifiedUUID = nil
            backupURL = nil
        }
        lock = nil
    }

    // MARK: - 菜单数据

    struct ModeOption {
        let mode: ModeInfo
        var label: String { "\(mode.width)×\(mode.height)（\(Modes.formatG(mode.hz)) Hz）" }
    }

    /// list_displays 的菜单版：按逻辑尺寸去重（每尺寸取与当前刷新率最接近者，其次最高）。
    static func hidpiOptions(for display: DisplaySnapshot) -> [ModeOption] {
        guard let current = display.mode else { return [] }
        let hidpi = DisplayIO.allModes(display.id).map(DisplayIO.info).filter {
            $0.usable && Modes.isHiDPI($0)
        }
        var best: [String: ModeInfo] = [:]
        for mode in hidpi {
            let key = "\(mode.width)x\(mode.height)"
            if let existing = best[key] {
                let preferNew = (abs(mode.hz - current.hz) < 0.6) != (abs(existing.hz - current.hz) < 0.6)
                if preferNew || (mode.hz > existing.hz &&
                    abs(mode.hz - current.hz) >= 0.6 && abs(existing.hz - current.hz) >= 0.6) {
                    best[key] = mode
                }
            } else {
                best[key] = mode
            }
        }
        return best.values
            .sorted { ($0.width, $0.height) < ($1.width, $1.height) }
            .map { ModeOption(mode: $0) }
    }
}
