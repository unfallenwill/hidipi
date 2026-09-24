/// Menu-bar app core: status item, menu, display reconfiguration callbacks and quit-time restore.
import AppKit
import CoreGraphics
import HidiPiCore
import HidiPiIcon

/// Closure carrier for NSMenuItem actions (target-action requires an ObjC object).
final class MenuItemAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let state = AppState()
    private var actions: [MenuItemAction] = []   // kept alive while the menu exists
    private var reconfigurationCallback: CGDisplayReconfigurationCallBack?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try state.teardown()
            return .terminateNow
        } catch {
            let choice = confirm("Restore incomplete on quit",
                "Restore did not fully complete: \(error)\n\nPhysical mode changes still revert "
                + "automatically once the app exits. Quit anyway?",
                confirmButton: "Quit", cancelButton: "Cancel")
            return choice ? .terminateNow : .terminateCancel
        }
    }

    // MARK: - Display change callbacks (replacing the Python preview loop's watchdog)

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
            NSLog("hidipi: startup failed: %@", String(describing: error))
            alert("Cannot Start", String(describing: error))
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
        // The menu renders on first open (menuWillOpen); no upfront build needed.
        // Login-autostart path: rebuild the virtual display from the recorded preference
        // once the main loop is up.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                if try self.state.restorePreferredVirtual(), let menu = self.statusItem.menu {
                    self.rebuild(menu)
                }
            } catch {
                self.alert("Virtual Display Auto-Rebuild Failed",
                    "\(error)\n\nYou can retry from the menu. The preference record is kept at "
                    + "\(VirtualPreference.url.path).")
            }
        }
    }

    /// Coalesces reconfiguration storms: CG fires many events per display transaction
    /// (and our own operations trigger them mid-flight), so at most one state-sync pass
    /// is ever pending on the main queue.
    private var stateSyncPending = false

    private func onDisplayReconfiguration() {
        guard !stateSyncPending else { return }
        stateSyncPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateSyncPending = false
            // The modified display went away: restore the still-connected ones and clear
            // state; the app stays alive. On failure, state is kept (quit retries it) — log it.
            if let id = self.state.modifiedDisplayID, !DisplayIO.isOnline(id) {
                do {
                    try self.state.restoreOriginalQuietly()
                } catch {
                    NSLog("hidipi: auto-restore after display disconnect failed: %@ (state kept, retried on quit)",
                          String(describing: error))
                }
            }
            // The virtual display vanished unexpectedly: clear runtime state but keep the
            // preference record so the next login still rebuilds it.
            if let controller = self.state.virtualController,
               !DisplayIO.isOnline(controller.displayID) {
                do {
                    try self.state.removeVirtual(clearPreference: false)
                } catch {
                    NSLog("hidipi: virtual display cleanup failed: %@ (state kept, retried on quit)",
                          String(describing: error))
                }
            }
            if let menu = self.statusItem.menu { self.rebuild(menu) }
        }
    }

    // MARK: - Menu construction

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
        menu.addItem(titled("About HidiPi") { [weak self] in
            self?.showAbout()
        })
        menu.addItem(titled("Quit (Restore Original Settings)", keyEquivalent: "q") {
            NSApp.terminate(nil)
        })
    }

    private func appendStatus(_ menu: NSMenu, snapshot: DisplayState?) {
        var text = "No display changes active"
        if state.virtualActive, let size = state.virtualSize {
            text = "Virtual display active: \(size.0)×\(size.1), HiDPI"
        } else if let id = state.modifiedDisplayID,
                  let current = DisplayIO.currentMode(id) {
            text = Modes.describe(current)
        } else if let only = snapshot?.displays.first, snapshot?.displays.count == 1 {
            text = Modes.describe(only.mode)
        }
        addDisabled(menu, text)
    }

    private func appendPhysicalSections(_ menu: NSMenu, snapshot: DisplayState?) {
        guard let displays = snapshot?.displays, !displays.isEmpty else {
            addDisabled(menu, "No online displays detected")
            return
        }
        for display in displays where display.vendor != VirtualBridge.vendorID {
            let title = "Display \(display.id) (\(display.main ? "main" : "secondary"))"
            let submenu = NSMenu()
            if state.virtualActive {
                addDisabled(submenu, "Remove the virtual display first")
            } else if display.inMirrorSet {
                addDisabled(submenu, "Mirroring active; disable it in System Settings first")
            } else {
                let options = AppState.hidpiOptions(for: display)
                if options.isEmpty {
                    addDisabled(submenu, "No HiDPI modes available")
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
            addDisabled(menu, "✓ Virtual display active" +
                (state.virtualSize.map { ": \($0.0)×\($0.1)" } ?? ""))
            menu.addItem(titled("Remove Virtual Display") { [weak self] in
                self?.run(.removeVirtual)
            })
        } else {
            let item = titled(state.physicalModified
                ? "Virtual Display (restore physical changes first)" : "Virtual Display")
            item.isEnabled = !state.physicalModified
            let submenu = NSMenu()
            for size in [(1920, 1080), (2560, 1440)] {
                let entry = titled("Create \(size.0)×\(size.1), HiDPI")
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
        let item = titled("Start at Login")
        item.state = LoginItem.isEnabled ? .on : .off
        bind(item) { [weak self] in
            guard let self else { return }
            do {
                try LoginItem.setEnabled(!LoginItem.isEnabled)
            } catch {
                self.alert("Login Item", String(describing: error))
            }
            // No rebuild needed: the menu re-renders on next open (menuWillOpen).
        }
        menu.addItem(item)
    }

    // MARK: - About panel

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        // Name and version come from the bundle's Info.plist; only the credits are custom.
        NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(
            string: "Menu-bar HiDPI control for physical and virtual displays.\n"
                + "https://github.com/unfallenwill/hidipi",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])])
    }

    // MARK: - Action execution and error presentation

    private enum Action {
        case enableHiDPI(display: DisplaySnapshot, wanted: ModeInfo)
        case createVirtual(size: (Int, Int))
        case removeVirtual
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
        }
        if case .failure(let error) = outcome {
            alert("Operation Failed", String(describing: error))
        }
        // No rebuild needed: invoking an item dismisses the menu, and the next open
        // re-renders via menuWillOpen.
    }

    // MARK: - Small helpers

    private func titled(_ title: String, keyEquivalent: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: keyEquivalent)
    }

    /// Adds a disabled row (status / hint lines).
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
        rebuild(menu)   // rebuilt on every open, replacing polling
    }
}
