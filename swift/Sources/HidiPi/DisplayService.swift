/// 移植 macos.py 的 Mac 类：快照、切换、恢复事务与核验 —— 安全核心。
import Foundation
import HidiPiCore
import CoreGraphics

struct DisplayService {
    /// macos.snapshot：全部在线显示器的完整状态。
    func snapshot(allowEmpty: Bool = false) throws -> BackupSnapshot {
        var displays: [DisplaySnapshot] = []
        for display in try DisplayIO.onlineIDs() {
            let bounds = CGDisplayBounds(display)
            let size = CGDisplayScreenSize(display)
            displays.append(DisplaySnapshot(
                id: display,
                uuid: try DisplayUUID.string(for: display),
                vendor: CGDisplayVendorNumber(display),
                model: CGDisplayModelNumber(display),
                serial: CGDisplaySerialNumber(display),
                builtin: CGDisplayIsBuiltin(display) != 0,
                main: CGDisplayIsMain(display) != 0,
                mirrorOf: CGDisplayMirrorsDisplay(display),
                inMirrorSet: CGDisplayIsInMirrorSet(display) != 0,
                origin: [Int(bounds.origin.x), Int(bounds.origin.y)],
                millimeters: [size.width, size.height],
                mode: DisplayIO.currentMode(display)))
        }
        guard !displays.isEmpty || allowEmpty else {
            throw HiDPIError("未读取到在线显示器。请在已登录桌面的本机运行；沙箱/SSH 会话可能无法访问 WindowServer。")
        }
        if displays.isEmpty {
            return BackupSnapshot(headlessCreated: Backup.timestamp(), macos: Backup.macosVersion(),
                                  systemFallback: nil)
        }
        return BackupSnapshot(created: Backup.timestamp(), macos: Backup.macosVersion(), displays: displays)
    }

    /// macos.pump / wait_until：泵运行循环的同时等待谓词成立。
    func waitUntil(timeout: TimeInterval, _ error: String, _ predicate: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try predicate() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw HiDPIError(error)
    }

    /// macos.set_mode：单事务切换（app-only —— 进程退出即回退）。
    func setMode(_ display: CGDirectDisplayID, expected: ModeInfo) throws {
        let candidates = DisplayIO.allModes(display).filter {
            Modes.modeMatches(DisplayIO.info($0), expected)
        }
        guard let mode = candidates.first else {
            throw HiDPIError("指定模式已不可用；尚未切换。")
        }
        var config: CGDisplayConfigRef?
        try DisplayIO.check(CGBeginDisplayConfiguration(&config), "开始显示配置")
        do {
            try DisplayIO.check(CGConfigureDisplayWithDisplayMode(config, display, mode, nil), "切换 HiDPI")
            try DisplayIO.check(CGCompleteDisplayConfiguration(config, CGConfigureOption.forAppOnly), "应用显示配置")
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
    }

    /// macos.restore：按 UUID 解析、逐台预检，然后单事务恢复模式/排列/镜像并核验。
    func restore(_ snapshot: BackupSnapshot) throws {
        if snapshot.schema == 2, snapshot.headless == true, snapshot.displays.isEmpty { return }
        let live = try Dictionary(uniqueKeysWithValues: DisplayIO.onlineIDs().map {
            (try DisplayUUID.string(for: $0), $0)
        })
        // 预检全部通过后才动任何显示器；mode_id 只作并列裁决（跨重启会变）。
        // CGDisplayMode 引用由数组持有（CF 桥接 +0），无需手动释放。
        var entries: [(id: CGDirectDisplayID, mode: CGDisplayMode, saved: DisplaySnapshot)] = []
        for saved in snapshot.displays {
            guard let display = live[saved.uuid] else {
                throw HiDPIError("备份中的显示器 \(saved.uuid) 未连接；请重新连接后恢复。")
            }
            guard let wanted = saved.mode else {
                throw HiDPIError("备份缺少原始模式，无法完整恢复。")
            }
            let matches = DisplayIO.allModes(display).filter {
                Modes.modeMatches(DisplayIO.info($0), wanted)
            }
            guard let best = matches.min(by: {
                // Python：mode_id 仅作并列裁决，匹配者排最前。
                let l = DisplayIO.info($0).modeID != wanted.modeID
                let r = DisplayIO.info($1).modeID != wanted.modeID
                return l != r ? !l : false
            }) else {
                throw HiDPIError("显示器 \(display) 的原始模式当前不可用：\(Modes.describe(wanted))")
            }
            entries.append((display, best, saved))
        }

        var config: CGDisplayConfigRef?
        try DisplayIO.check(CGBeginDisplayConfiguration(&config), "开始显示配置")
        do {
            for e in entries {
                try DisplayIO.check(CGConfigureDisplayMirrorOfDisplay(config, e.id, kCGNullDirectDisplay), "解除镜像")
            }
            for e in entries {
                try DisplayIO.check(CGConfigureDisplayWithDisplayMode(config, e.id, e.mode, nil), "恢复原始模式")
                if e.saved.mirrorOf == 0 {
                    try DisplayIO.check(CGConfigureDisplayOrigin(config, e.id,
                        Int32(e.saved.origin[0]), Int32(e.saved.origin[1])), "恢复屏幕排列")
                }
            }
            for e in entries where e.saved.mirrorOf != 0 {
                guard let source = entries.first(where: { $0.saved.id == e.saved.mirrorOf }) else {
                    throw HiDPIError("备份中的镜像源不完整。")
                }
                try DisplayIO.check(CGConfigureDisplayMirrorOfDisplay(config, e.id, source.id), "恢复原镜像")
            }
            try DisplayIO.check(CGCompleteDisplayConfiguration(config, CGConfigureOption.permanently), "应用显示配置")
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
        try waitUntil(timeout: 6, "恢复后的分辨率或排列未通过核验") {
            entries.allSatisfy { e in
                guard Modes.modeMatches(DisplayIO.currentMode(e.id), e.saved.mode!) else { return false }
                let mirror = CGDisplayMirrorsDisplay(e.id)
                let expectedMirror = e.saved.mirrorOf != 0
                    ? entries.first { $0.saved.id == e.saved.mirrorOf }!.id : kCGNullDirectDisplay
                if mirror != expectedMirror { return false }
                if e.saved.mirrorOf == 0 {
                    let bounds = CGDisplayBounds(e.id)
                    if [Int(bounds.origin.x), Int(bounds.origin.y)] != e.saved.origin { return false }
                }
                return true
            }
        }
    }

    /// virtual.restore_connected：只恢复仍在线的屏；断开的屏保留备份待手动恢复。
    func restoreConnected(_ snapshot: BackupSnapshot) throws {
        guard snapshot.schema != 2 else { return }
        let live = Set(try DisplayIO.onlineIDs().map { try DisplayUUID.string(for: $0) })
        let connected = snapshot.displays.filter { live.contains($0.uuid) }
        if connected.count != snapshot.displays.count {
            NSLog("hidipi: 部分原显示器已断开；其设置备份仍保留，重新连接后可手动恢复。")
        }
        guard !connected.isEmpty else { return }
        let ids = Set(connected.map(\.id))
        if connected.contains(where: { $0.mirrorOf != 0 && !ids.contains($0.mirrorOf) }) {
            throw HiDPIError("原镜像组不完整；请连接原显示器后从备份恢复。")
        }
        var partial = snapshot
        partial.displays = connected
        try restore(partial)
    }
}
