/// The pure description of the status menu, derived from app state — the testable half of
/// menu construction, independent of AppKit and live displays. AppDelegate renders a
/// MenuModel into an NSMenu and wires the actions.
import Foundation
import HidiPiCore

/// One selectable HiDPI mode in a display's submenu.
struct ModeOption {
    let display: DisplaySnapshot
    let mode: ModeInfo
    var title: String { "\(mode.width)×\(mode.height) (\(Modes.formatG(mode.hz)) Hz)" }
    var checked: Bool { Modes.modeMatches(display.mode, mode) }
}

/// Everything the menu needs to know about the app: a pure value snapshot of AppState.
struct MenuState {
    var snapshot: DisplayState?
    var virtualActive: Bool
    var virtualSize: (Int, Int)?
    var physicalModified: Bool
    var modifiedDisplayID: UInt32?
    var loginItemEnabled: Bool

    init(snapshot: DisplayState? = nil, virtualActive: Bool = false, virtualSize: (Int, Int)? = nil,
         physicalModified: Bool = false, modifiedDisplayID: UInt32? = nil,
         loginItemEnabled: Bool = false) {
        self.snapshot = snapshot; self.virtualActive = virtualActive; self.virtualSize = virtualSize
        self.physicalModified = physicalModified; self.modifiedDisplayID = modifiedDisplayID
        self.loginItemEnabled = loginItemEnabled
    }
}

struct MenuModel {
    struct DisplaySection {
        let title: String
        /// Shown instead of options: virtual active / mirroring / no modes.
        let hint: String?
        let options: [ModeOption]
    }

    let statusText: String
    let noDisplays: Bool
    let displaySections: [DisplaySection]
    let virtualActive: Bool
    /// "✓ Virtual display active: W×H" when active, otherwise the submenu parent title.
    let virtualTitle: String
    let virtualEnabled: Bool
    let createSizes: [(Int, Int)]
    let loginItemChecked: Bool

    /// Ports the former appendStatus / appendPhysicalSections / appendVirtualSection logic.
    /// hidpiOptions is injected so tests can supply fixtures instead of CG enumeration.
    static func build(_ state: MenuState,
                      hidpiOptions: (DisplaySnapshot) -> [ModeOption] = AppState.hidpiOptions) -> MenuModel {
        var statusText = "No display changes active"
        if state.virtualActive, let size = state.virtualSize {
            statusText = "Virtual display active: \(size.0)×\(size.1), HiDPI"
        } else if let id = state.modifiedDisplayID, let current = DisplayIO.currentMode(id) {
            statusText = Modes.describe(current)
        } else if let only = state.snapshot?.displays.first, state.snapshot?.displays.count == 1 {
            statusText = Modes.describe(only.mode)
        }

        var noDisplays = false
        var sections: [DisplaySection] = []
        if let displays = state.snapshot?.displays, !displays.isEmpty {
            for display in displays where display.vendor != VirtualBridge.vendorID {
                let title = "Display \(display.id) (\(display.main ? "main" : "secondary"))"
                var hint: String?
                var options: [ModeOption] = []
                if state.virtualActive {
                    hint = "Remove the virtual display first"
                } else if display.inMirrorSet {
                    hint = "Mirroring active; disable it in System Settings first"
                } else {
                    let available = hidpiOptions(display)
                    if available.isEmpty {
                        hint = "No HiDPI modes available"
                    } else {
                        options = available
                    }
                }
                sections.append(DisplaySection(title: title, hint: hint, options: options))
            }
        } else {
            noDisplays = true
        }

        let virtualTitle: String
        let virtualEnabled: Bool
        let createSizes: [(Int, Int)]
        if state.virtualActive {
            virtualTitle = "✓ Virtual display active" +
                (state.virtualSize.map { ": \($0.0)×\($0.1)" } ?? "")
            virtualEnabled = true
            createSizes = []
        } else {
            virtualTitle = state.physicalModified
                ? "Virtual Display (restore physical changes first)" : "Virtual Display"
            virtualEnabled = !state.physicalModified
            createSizes = [(1920, 1080), (2560, 1440)]
        }

        return MenuModel(statusText: statusText, noDisplays: noDisplays,
                         displaySections: sections, virtualActive: state.virtualActive,
                         virtualTitle: virtualTitle, virtualEnabled: virtualEnabled,
                         createSizes: createSizes, loginItemChecked: state.loginItemEnabled)
    }
}
