/// 菜单栏 App 本体：状态项、菜单、显示器重配置回调与退出恢复。
import AppKit
import CoreGraphics
import HidiPiCore
import HidiPiIcon

/// NSMenuItem 动作的闭包承载（target-action 必须是 ObjC 对象）。
final class MenuItemAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let state = AppState()
    private var actions: [MenuItemAction] = []   // 菜单重建期间保持强引用
    private var reconfigurationCallback: CGDisplayReconfigurationCallBack?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try state.teardown()
            return .terminateNow
        } catch {
            let choice = confirm("退出时未能完全恢复",
                "恢复未完成：\(error)\n\n所有备份仍保留在 \(Paths.backupDir.path)，"
                + "可随时从菜单或 Python 版 hidipi restore 手动恢复。仍要退出吗？",
                confirmButton: "退出", cancelButton: "取消")
            return choice ? .terminateNow : .terminateCancel
        }
    }

    // MARK: - 显示器变化回调（替代 Python 预览循环的看门狗）

    private func registerReconfigurationCallback() {
        reconfigurationCallback = { _, _, _ in
            AppDelegate.shared?.onDisplayReconfiguration()
        }
        if let callback = reconfigurationCallback {
            CGDisplayRegisterReconfigurationCallback(callback, nil)
        }
    }

    private static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        do {
            try state.acquireLock()
        } catch {
            NSLog("hidipi: 启动失败：%@", String(describing: error))
            alert("无法启动", String(describing: error))
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = IconDrawing.statusItemIcon()
        statusItem.button?.toolTip = "hidipi"
        statusItem.button?.setAccessibilityLabel("hidipi")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        registerReconfigurationCallback()
        rebuild(menu)
    }

    private func onDisplayReconfiguration() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 被修改的显示器已断开：恢复仍连接的屏并清除状态，App 存活。
            if let id = self.state.modifiedDisplayID,
               (try? DisplayIO.onlineIDs())?.contains(id) == false {
                try? self.state.restoreOriginalQuietly()
            }
            // 虚拟屏意外消失：清除状态（引用仍持有，等待系统回收）。
            if let controller = self.state.virtualController,
               (try? DisplayIO.onlineIDs())?.contains(controller.displayID) == false {
                _ = try? self.state.removeVirtual()
            }
            if let menu = self.statusItem.menu { self.rebuild(menu) }
        }
    }

    // MARK: - 菜单构建

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        actions.removeAll()
        let snapshot = try? state.service.snapshot()
        appendStatus(menu, snapshot: snapshot)
        menu.addItem(.separator())
        appendPhysicalSections(menu, snapshot: snapshot)
        menu.addItem(.separator())
        appendVirtualSection(menu)
        menu.addItem(.separator())
        appendLoginItemSection(menu)
        menu.addItem(.separator())
        appendBackupSection(menu)
        menu.addItem(.separator())
        menu.addItem(titled("退出（恢复原始设置）", keyEquivalent: "q") { [weak self] in
            NSApp.terminate(nil)
        })
    }

    private func appendStatus(_ menu: NSMenu, snapshot: BackupSnapshot?) {
        var text = "未修改显示设置"
        if state.virtualActive, let size = state.virtualSize {
            text = "虚拟屏幕运行中：\(size.0)×\(size.1)，HiDPI"
        } else if let id = state.modifiedDisplayID,
                  let current = DisplayIO.currentMode(id) {
            text = Modes.describe(current)
        } else if let only = snapshot?.displays.first, snapshot?.displays.count == 1 {
            text = Modes.describe(only.mode)
        }
        addDisabled(menu, text)
    }

    private func appendPhysicalSections(_ menu: NSMenu, snapshot: BackupSnapshot?) {
        guard let displays = snapshot?.displays, !displays.isEmpty else {
            addDisabled(menu, "未读取到在线显示器")
            return
        }
        for display in displays where display.vendor != VirtualBridge.vendorID {
            let title = "显示器 \(display.id)（\(display.main ? "主屏" : "副屏")）"
            let submenu = NSMenu()
            if state.virtualActive {
                addDisabled(submenu, "请先移除虚拟屏幕")
            } else if display.inMirrorSet {
                addDisabled(submenu, "正在镜像，请先在系统设置解除")
            } else {
                let options = AppState.hidpiOptions(for: display)
                if options.isEmpty {
                    addDisabled(submenu, "无可用 HiDPI 模式")
                } else {
                    for option in options {
                        let item = titled(option.label)
                        item.state = Modes.modeMatches(display.mode, option.mode) ? .on : .off
                        bind(item) { [weak self] in
                            self?.run(.enableHiDPI(display: display, wanted: option.mode))
                        }
                        submenu.addItem(item)
                    }
                }
            }
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
        }
    }

    private func appendVirtualSection(_ menu: NSMenu) {
        if state.virtualActive {
            addDisabled(menu, "✓ 虚拟屏幕运行中" +
                (state.virtualSize.map { "：\($0.0)×\($0.1)" } ?? ""))
            menu.addItem(titled("移除虚拟屏幕") { [weak self] in
                self?.run(.removeVirtual)
            })
        } else {
            let item = titled(state.physicalModified ? "虚拟屏幕（请先退出物理屏修改）" : "虚拟屏幕")
            item.isEnabled = !state.physicalModified
            let submenu = NSMenu()
            for size in [(1920, 1080), (2560, 1440)] {
                let entry = titled("创建 \(size.0)×\(size.1)，HiDPI")
                entry.isEnabled = !state.physicalModified
                bind(entry) { [weak self] in
                    self?.run(.createVirtual(size: size))
                }
                submenu.addItem(entry)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
    }

    private func appendLoginItemSection(_ menu: NSMenu) {
        let item = titled("登录时启动")
        item.state = LoginItem.isEnabled ? .on : .off
        bind(item) { [weak self] in
            guard let self else { return }
            do {
                try LoginItem.setEnabled(!LoginItem.isEnabled)
            } catch {
                self.alert("登录启动", String(describing: error))
            }
            if let menu = self.statusItem.menu { self.rebuild(menu) }
        }
        menu.addItem(item)
    }

    private func appendBackupSection(_ menu: NSMenu) {
        let item = titled("从备份恢复…")
        let entries = Self.recentBackups(limit: 8)
        guard !entries.isEmpty else {
            item.isEnabled = false
            return
        }
        let submenu = NSMenu()
        for entry in entries {
            let entryItem = titled(entry.label)
            bind(entryItem) { [weak self] in
                self?.run(.restore(url: entry.url))
            }
            submenu.addItem(entryItem)
        }
        item.submenu = submenu
        menu.addItem(item)
    }

    struct BackupEntry {
        let url: URL
        let label: String
    }

    /// 最近备份：文件名解析时间，读文件数显示器台数（读不动则标 ?）。
    static func recentBackups(limit: Int) -> [BackupEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.backupDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("display-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        return files.prefix(limit).map { url in
            // display-20260922-164537-286bef5c → "09-22 16:45 · N 台显示器"
            let name = url.deletingPathExtension().lastPathComponent
            var label = name
            let parts = name.split(separator: "-")   // ["display","20260922","164537","286bef5c"]
            if parts.count == 4, parts[0] == "display",
               let date = parts[1].count == 8 ? Optional(parts[1]) : nil,
               let time = parts[2].count == 6 ? Optional(parts[2]) : nil {
                let count = (try? Backup.decode(try Data(contentsOf: url)))?.displays.count
                label = "\(date.suffix(4).prefix(2))-\(date.suffix(2)) "
                    + "\(time.prefix(2)):\(time.dropFirst(2).prefix(2)) · "
                    + (count.map { "\($0) 台显示器" } ?? "?")
            }
            return BackupEntry(url: url, label: label)
        }
    }

    // MARK: - 动作执行与错误呈现

    private enum Action {
        case enableHiDPI(display: DisplaySnapshot, wanted: ModeInfo)
        case createVirtual(size: (Int, Int))
        case removeVirtual
        case restore(url: URL)
    }

    private func run(_ action: Action) {
        let outcome: Result<Void, Error>
        switch action {
        case .enableHiDPI(let display, let wanted):
            outcome = Result { try state.enableHiDPI(on: display, wanted: wanted) }
        case .createVirtual(let size):
            outcome = Result { try state.createVirtual(size: size) }
        case .removeVirtual:
            outcome = Result { try state.removeVirtual() }
        case .restore(let url):
            outcome = Result { try state.restore(from: url) }
        }
        if case .failure(let error) = outcome {
            alert("操作失败", String(describing: error))
        }
        if let menu = statusItem.menu { rebuild(menu) }
    }

    // MARK: - 小工具

    private func titled(_ title: String, keyEquivalent: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: keyEquivalent)
    }

    /// 加一个禁用项（状态/提示行）。
    private func addDisabled(_ menu: NSMenu, _ title: String) {
        let item = titled(title)
        item.isEnabled = false
        menu.addItem(item)
    }

    private func titled(_ title: String, keyEquivalent: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: keyEquivalent)
        bind(item, handler)
        return item
    }

    private func bind(_ item: NSMenuItem, _ handler: @escaping () -> Void) {
        let action = MenuItemAction(handler)
        item.target = action
        item.action = #selector(MenuItemAction.invoke)
        actions.append(action)
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func confirm(_ title: String, _ message: String,
                         confirmButton: String, cancelButton: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmButton)
        alert.addButton(withTitle: cancelButton)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)   // 每次打开都重建，替代轮询
    }
}
