/// Menu-bar app core: status item, menu rendering, display reconfiguration callbacks and
/// quit-time restore. Menu structure decisions live in MenuModel (pure, tested); this
/// type gathers state and renders it into NSMenu items with actions wired.
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

/// Dialog presentation, injectable for tests; the defaults show real AppKit UI.
struct DialogPresenter {
    var alert: (_ title: String, _ message: String) -> Void = { title, message in
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
    var confirm: (_ title: String, _ message: String,
                  _ confirmButton: String, _ cancelButton: String) -> Bool =
    { title, message, confirmButton, cancelButton in
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmButton)
        alert.addButton(withTitle: cancelButton)
        return alert.runModal() == .alertFirstButtonReturn
    }
    var about: () -> Void = {
        NSApp.activate(ignoringOtherApps: true)
        // Name and version come from the bundle's Info.plist; only the credits are custom.
        NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(
            string: "Menu-bar HiDPI control for physical and virtual displays.\n"
                + "https://github.com/unfallenwill/hidipi",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    let state: AppState
    var dialogs = DialogPresenter()   // replaced by tests
    private var actions: [MenuItemAction] = []   // kept alive while the menu exists
    private var reconfigurationCallback: CGDisplayReconfigurationCallBack?

    /// state is injectable for tests; production always uses a fresh AppState.
    init(state: AppState = AppState()) {
        self.state = state
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try state.teardown()
            return .terminateNow
        } catch {
            let choice = dialogs.confirm("Restore incomplete on quit",
                "Restore did not fully complete: \(error)\n\nPhysical mode changes still revert "
                + "automatically once the app exits. Quit anyway?", "Quit", "Cancel")
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
            dialogs.alert("Cannot Start", String(describing: error))
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = IconDrawing.statusItemIcon()
        statusItem?.button?.toolTip = "hidipi"
        statusItem?.button?.setAccessibilityLabel("hidipi")
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        registerReconfigurationCallback()
        // The menu renders on first open (menuWillOpen); no upfront build needed.
        // Login-autostart path: rebuild the virtual display from the recorded preference
        // once the main loop is up.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                if try self.state.restorePreferredVirtual(), let menu = self.statusItem?.menu {
                    self.rebuild(menu)
                }
            } catch {
                self.dialogs.alert("Virtual Display Auto-Rebuild Failed",
                    "\(error)\n\nYou can retry from the menu. The preference record is kept at "
                    + "\(VirtualPreference.url.path).")
            }
        }
    }

    /// Coalesces reconfiguration storms: CG fires many events per display transaction
    /// (and our own operations trigger them mid-flight), so at most one state-sync pass
    /// is ever pending on the main queue.
    private var stateSyncPending = false

    func onDisplayReconfiguration() {
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
            if let menu = self.statusItem?.menu { self.rebuild(menu) }
        }
    }

    // MARK: - Menu rendering

    private func currentState() -> MenuState {
        MenuState(snapshot: try? state.service.snapshot(),
                  virtualActive: state.virtualActive,
                  virtualSize: state.virtualSize,
                  physicalModified: state.physicalModified,
                  modifiedDisplayID: state.modifiedDisplayID,
                  loginItemEnabled: LoginItem.isEnabled)
    }

    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        actions.removeAll()
        render(MenuModel.build(currentState()), into: menu)
    }

    func render(_ model: MenuModel, into menu: NSMenu) {
        addDisabled(menu, model.statusText)
        menu.addItem(.separator())
        if model.noDisplays {
            addDisabled(menu, "No online displays detected")
        } else {
            for section in model.displaySections {
                let submenu = NSMenu()
                if let hint = section.hint {
                    addDisabled(submenu, hint)
                } else {
                    for option in section.options {
                        let entry = titled(option.title)
                        entry.state = option.checked ? .on : .off
                        bind(entry) { [weak self] in
                            self?.run(.enableHiDPI(display: option.display, wanted: option.mode))
                        }
                        submenu.addItem(entry)
                    }
                }
                menu.addItem(withTitle: section.title, action: nil, keyEquivalent: "").submenu = submenu
            }
        }
        menu.addItem(.separator())
        if model.virtualActive {
            addDisabled(menu, model.virtualTitle)
            menu.addItem(titled("Remove Virtual Display") { [weak self] in
                self?.run(.removeVirtual)
            })
        } else {
            let item = titled(model.virtualTitle)
            item.isEnabled = model.virtualEnabled
            let submenu = NSMenu()
            for size in model.createSizes {
                let entry = titled("Create \(size.0)×\(size.1), HiDPI")
                entry.isEnabled = model.virtualEnabled
                bind(entry) { [weak self] in
                    self?.run(.createVirtual(size: size))
                }
                submenu.addItem(entry)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let login = titled("Start at Login")
        login.state = model.loginItemChecked ? .on : .off
        bind(login) { [weak self] in
            guard let self else { return }
            do {
                try LoginItem.setEnabled(!LoginItem.isEnabled)
            } catch {
                self.dialogs.alert("Login Item", String(describing: error))
            }
            // No rebuild needed: the menu re-renders on next open (menuWillOpen).
        }
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(titled("About HidiPi") { [weak self] in
            self?.dialogs.about()
        })
        menu.addItem(titled("Quit (Restore Original Settings)", keyEquivalent: "q") {
            NSApp.terminate(nil)
        })
    }

    // MARK: - Action execution and error presentation

    enum Action {
        case enableHiDPI(display: DisplaySnapshot, wanted: ModeInfo)
        case createVirtual(size: (Int, Int))
        case removeVirtual
    }

    func run(_ action: Action) {
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
            dialogs.alert("Operation Failed", String(describing: error))
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
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)   // rebuilt on every open, replacing polling
    }
}
