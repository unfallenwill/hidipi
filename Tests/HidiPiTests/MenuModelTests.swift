import AppKit
import Foundation
import Testing
import HidiPiCore
@testable import HidiPi

private let currentMode = ModeInfo(width: 2560, height: 1440, pixelWidth: 2560,
                                   pixelHeight: 1440, hz: 60)

private func display(id: UInt32 = 2, vendor: UInt32 = 1, main: Bool = true,
                     inMirrorSet: Bool = false,
                     mode: ModeInfo? = currentMode) -> DisplaySnapshot {
    DisplaySnapshot(id: id, uuid: "78589D3B-0A4E-47C1-BF35-FFEA9DABBEB0", vendor: vendor, model: 1,
                    main: main, mirrorOf: 0, inMirrorSet: inMirrorSet,
                    origin: [0, 0], mode: mode)
}

private func build(_ state: MenuState,
                   options: [ModeOption] = []) -> MenuModel {
    MenuModel.build(state, hidpiOptions: { _ in options })
}

@Test func idleStateShowsPlaceholderStatus() {
    let model = build(MenuState())
    #expect(model.statusText == "No display changes active")
    #expect(model.noDisplays)
    #expect(model.displaySections.isEmpty)
    #expect(!model.virtualActive)
    #expect(model.virtualEnabled)
    #expect(model.createSizes.map { "\($0.0)x\($0.1)" } == ["1920x1080", "2560x1440"])
    #expect(!model.loginItemChecked)
}

@Test func singleDisplayStatusDescribesItsMode() {
    let model = build(MenuState(snapshot: DisplayState(displays: [display()])))
    #expect(!model.noDisplays)
    #expect(model.statusText == "2560×1440, rendered 2560×1440, 60 Hz, standard DPI")
    #expect(model.displaySections.count == 1)
    #expect(model.displaySections[0].title == "Display 2 (main)")
}

@Test func secondaryAndVirtualVendorDisplaysAreLabeledOrSkipped() {
    let model = build(MenuState(snapshot: DisplayState(displays: [
        display(main: false),
        display(id: 9, vendor: VirtualBridge.vendorID),
    ])))
    #expect(model.displaySections.count == 1)                 // virtual vendor skipped
    #expect(model.displaySections[0].title == "Display 2 (secondary)")
}

@Test func virtualActiveChangesStatusAndHints() {
    let model = build(MenuState(snapshot: DisplayState(displays: [display()]),
                                virtualActive: true, virtualSize: (1920, 1080)))
    #expect(model.statusText == "Virtual display active: 1920×1080, HiDPI")
    #expect(model.displaySections[0].hint == "Remove the virtual display first")
    #expect(model.displaySections[0].options.isEmpty)
    #expect(model.virtualActive)
    #expect(model.virtualTitle == "✓ Virtual display active: 1920×1080")
    #expect(model.createSizes.isEmpty)
}

@Test func physicalModifiedDisablesVirtualCreation() {
    let model = build(MenuState(physicalModified: true))
    #expect(model.virtualTitle == "Virtual Display (restore physical changes first)")
    #expect(!model.virtualEnabled)
}

@Test func mirroredDisplayShowsUnmirrorHint() {
    let model = build(MenuState(snapshot: DisplayState(displays: [display(inMirrorSet: true)])))
    #expect(model.displaySections[0].hint == "Mirroring active; disable it in System Settings first")
}

@Test func optionsCarryTitlesAndCheckmarks() {
    let hidpi = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 60)
    let option = ModeOption(display: display(), mode: hidpi)
    let model = build(MenuState(snapshot: DisplayState(displays: [display()])), options: [option])
    #expect(model.displaySections[0].hint == nil)
    #expect(model.displaySections[0].options.count == 1)
    #expect(model.displaySections[0].options[0].title == "1920×1080 (60 Hz)")
    #expect(!model.displaySections[0].options[0].checked)   // differs from the current mode
    let matching = ModeOption(display: display(), mode: currentMode)
    #expect(matching.checked)
}

@Test func noAvailableModesShowsHint() {
    let model = build(MenuState(snapshot: DisplayState(displays: [display()])), options: [])
    #expect(model.displaySections[0].hint == "No HiDPI modes available")
}

// MARK: - Rendering (NSMenu construction happens on the main thread, like the app)

@Test func renderProducesACompleteIdleMenu() throws {
    try onMain {
        let delegate = AppDelegate(state: AppState())
        let menu = NSMenu()
        delegate.render(build(MenuState(loginItemEnabled: true)), into: menu)
        let titles = menu.items.map(\.title)
        #expect(titles.first == "No display changes active")
        #expect(titles.contains("No online displays detected"))
        #expect(titles.contains("Virtual Display"))
        #expect(titles.contains("Start at Login"))
        #expect(titles.contains("About HidiPi"))
        #expect(titles.contains("Quit (Restore Original Settings)"))
        let login = menu.items.first { $0.title == "Start at Login" }!
        #expect(login.state == .on)
    }
}

@Test func renderReflectsVirtualActiveState() throws {
    try onMain {
        let delegate = AppDelegate(state: AppState())
        let menu = NSMenu()
        delegate.render(build(MenuState(virtualActive: true, virtualSize: (2560, 1440))), into: menu)
        let titles = menu.items.map(\.title)
        #expect(titles.contains("✓ Virtual display active: 2560×1440"))
        #expect(titles.contains("Remove Virtual Display"))
        #expect(!titles.contains("Virtual Display"))
    }
}

@Test func renderWiresDisplaySubmenusWithOptions() throws {
    try onMain {
        let delegate = AppDelegate(state: AppState())
        let menu = NSMenu()
        let snapshot = DisplayState(displays: [display()])
        let hidpi = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 60)
        delegate.render(build(MenuState(snapshot: snapshot),
                              options: [ModeOption(display: display(), mode: hidpi)]), into: menu)
        let displayItem = menu.items.first { $0.title == "Display 2 (main)" }!
        #expect(displayItem.submenu != nil)
        #expect(displayItem.submenu!.items.map(\.title) == ["1920×1080 (60 Hz)"])
        #expect(displayItem.submenu!.items[0].isEnabled)
    }
}

/// AppKit menu construction wants the main thread; hop there synchronously for the test body.
private func onMain(_ body: () throws -> Void) rethrows {
    if Thread.isMainThread {
        try body()
    } else {
        try DispatchQueue.main.sync { try body() }
    }
}

@Test func rebuildGathersLiveStateIntoTheMenu() throws {
    try onMain {
        let delegate = AppDelegate(state: AppState())
        let menu = NSMenu()
        delegate.rebuild(menu)
        let titles = menu.items.map(\.title)
        #expect(titles.contains("About HidiPi"))
        #expect(titles.contains("Quit (Restore Original Settings)"))
        #expect(!(titles.first ?? "").isEmpty)   // a status row is always present
    }
}
