/// Port of virtual.py: a pure-Swift bridge to the CGVirtualDisplay private interface and its lifecycle.
///
/// Verified on this machine: the CGVirtualDisplay* classes exist at runtime but do not
/// declare our protocols, so `as!` downcasts fail; `unsafeBitCast` to an @objc protocol
/// existential (single-pointer layout) dispatches setters/getters correctly. The
/// alloc/init family uses explicit objc_msgSend + Unmanaged: alloc does not claim (+1 is
/// swallowed by init), and the init result is takeRetainedValue exactly once — equivalent
/// to ObjC ARC. The earlier perform(alloc)+perform(init) double takeRetainedValue caused
/// over-release crashes when the GUI event loop drained its autorelease pool.
import Foundation
import HidiPiCore
import CoreGraphics
import Dispatch
import ObjectiveC

@objc private protocol CGVirtualDisplayDescriptorProto: NSObjectProtocol {
    @objc(setName:) func setName(_ value: String)
    @objc(setQueue:) func setQueue(_ value: DispatchQueue)
    @objc(setMaxPixelsWide:) func setMaxPixelsWide(_ value: UInt32)
    @objc(setMaxPixelsHigh:) func setMaxPixelsHigh(_ value: UInt32)
    @objc(setSizeInMillimeters:) func setSizeInMillimeters(_ value: CGSize)
    @objc(setVendorID:) func setVendorID(_ value: UInt32)
    @objc(setProductID:) func setProductID(_ value: UInt32)
    @objc(setSerialNum:) func setSerialNum(_ value: UInt32)
    @objc(setSerialNumber:) func setSerialNumber(_ value: UInt32)
    @objc(setRedPrimary:) func setRedPrimary(_ value: CGPoint)
    @objc(setGreenPrimary:) func setGreenPrimary(_ value: CGPoint)
    @objc(setBluePrimary:) func setBluePrimary(_ value: CGPoint)
    @objc(setWhitePoint:) func setWhitePoint(_ value: CGPoint)
}

@objc private protocol CGVirtualDisplaySettingsProto: NSObjectProtocol {
    @objc(setHiDPI:) func setHiDPI(_ value: UInt32)
    @objc(setModes:) func setModes(_ value: NSArray)
}

@objc private protocol CGVirtualDisplayProto: NSObjectProtocol {
    var displayID: UInt32 { get }
    @objc(applySettings:) func applySettings(_ settings: AnyObject) -> Bool
}

enum VirtualBridge {
    static let vendorID: UInt32 = 0xF0F0

    // —— Explicit objc_msgSend bridge (ownership equivalent to ObjC ARC, avoiding the
    //     double takeRetainedValue of the perform/protocol init family that caused
    //     over-release crashes) ——
    private typealias AllocFn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
    private typealias InitFn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
    private typealias InitWithDescriptorFn =
        @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>
    private typealias InitModeFn =
        @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>

    private static func classObject(_ className: String) throws -> AnyObject {
        guard let anyClass: AnyObject = NSClassFromString(className) else {
            throw HiDPIError("This macOS lacks \(className); the virtual display interface is unavailable.")
        }
        return anyClass
    }

    /// objc_msgSend is marked unavailable in Swift (variadic form); fetch the raw address via dlsym.
    private static func rawMsgSend() -> UnsafeMutableRawPointer {
        if let symbol = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend") { return symbol }
        fatalError("objc_msgSend unavailable")
    }

    /// alloc does not claim (+1 is swallowed by the init family); init's result is claimed once.
    private static func alloc(_ className: String) throws -> AnyObject {
        let fn = unsafeBitCast(rawMsgSend(), to: AllocFn.self)
        return fn(try classObject(className), sel_registerName("alloc")).takeUnretainedValue()
    }

    /// Plain objects (descriptor/settings etc.): alloc + init.
    /// init is mandatory: an uninitialized object's storage is nil and setters silently no-op.
    static func instantiate(_ className: String) throws -> NSObject {
        let fn = unsafeBitCast(rawMsgSend(), to: InitFn.self)
        let initialized = fn(try alloc(className), sel_registerName("init"))
        guard let object = initialized.takeRetainedValue() as? NSObject else {
            throw HiDPIError("Cannot initialize \(className)")
        }
        return object
    }

    /// CGVirtualDisplayMode: initWithWidth:height:refreshRate:.
    static func makeMode(width: UInt32, height: UInt32, refreshRate: Double) throws -> AnyObject {
        let fn = unsafeBitCast(rawMsgSend(), to: InitModeFn.self)
        return fn(try alloc("CGVirtualDisplayMode"),
                  sel_registerName("initWithWidth:height:refreshRate:"),
                  width, height, refreshRate).takeRetainedValue()
    }

    /// CGVirtualDisplay: initWithDescriptor:.
    static func makeDisplay(descriptor: AnyObject) throws -> AnyObject {
        let fn = unsafeBitCast(rawMsgSend(), to: InitWithDescriptorFn.self)
        return fn(try alloc("CGVirtualDisplay"),
                  sel_registerName("initWithDescriptor:"),
                  descriptor).takeRetainedValue()
    }
}

/// virtual.VirtualDisplay: holding the strong reference keeps the virtual display alive;
/// releasing it tears it down.
final class VirtualDisplayController {
    private let service: DisplayService
    private var display: AnyObject?
    private(set) var displayID: CGDirectDisplayID = 0

    init(service: DisplayService) { self.service = service }

    #if arch(arm64)
    /// The constraints of virtual.validate_options.
    static func validateOptions(size: (Int, Int), refresh: Double) throws {
        guard refresh.isFinite, (24...120).contains(refresh) else {
            throw HiDPIError("Virtual display refresh rate must be between 24 and 120 Hz.")
        }
        guard max(size.0, size.1) <= 3840, size.0 * size.1 <= 8_294_400 else {
            throw HiDPIError("Virtual display logical size is capped at 3840×2160 (or equal pixel count in portrait).")
        }
    }

    /// virtual.VirtualDisplay.start: create → apply mode → wait for online → verify.
    func start(size: (Int, Int), refresh: Double) throws -> CGDirectDisplayID {
        let (w, h) = (UInt32(size.0), UInt32(size.1))

        let descriptor = try VirtualBridge.instantiate("CGVirtualDisplayDescriptor")
        let d = unsafeBitCast(descriptor, to: CGVirtualDisplayDescriptorProto.self)
        d.setName("HiDPI Virtual Display")
        d.setQueue(DispatchQueue.global())
        d.setMaxPixelsWide(w * 2)
        d.setMaxPixelsHigh(h * 2)
        d.setSizeInMillimeters(CGSize(width: Double(w) * 25.4 / 110, height: Double(h) * 25.4 / 110))
        d.setVendorID(VirtualBridge.vendorID)
        d.setProductID(1 + ((w * 31 + h) % 65534))
        d.setSerialNum(1)
        d.setSerialNumber(1)
        d.setRedPrimary(CGPoint(x: 0.64, y: 0.33))
        d.setGreenPrimary(CGPoint(x: 0.30, y: 0.60))
        d.setBluePrimary(CGPoint(x: 0.15, y: 0.06))
        d.setWhitePoint(CGPoint(x: 0.3127, y: 0.3290))

        let instance = try VirtualBridge.makeDisplay(descriptor: descriptor)
        display = instance
        let proto = unsafeBitCast(instance, to: CGVirtualDisplayProto.self)
        let id = proto.displayID
        guard id != 0 else { throw HiDPIError("macOS refused to create the virtual display. Run in a logged-in desktop session.") }
        displayID = id
        NSLog("hidipi: virtual display object created, ID=%u, waiting for modes.", id)

        let settings = try VirtualBridge.instantiate("CGVirtualDisplaySettings")
        let s = unsafeBitCast(settings, to: CGVirtualDisplaySettingsProto.self)
        s.setHiDPI(1)
        // With HiDPI on, the mode size is the logical point count.
        let mode = try VirtualBridge.makeMode(width: w, height: h, refreshRate: refresh)
        s.setModes(NSArray(object: mode))
        guard proto.applySettings(settings) else {
            throw HiDPIError("macOS refused to apply the virtual display mode.")
        }

        try service.waitUntil(timeout: 10, "The virtual display did not come online in time") {
            DisplayIO.isOnline(id) && DisplayIO.currentMode(id) != nil
        }
        let expected = ModeInfo(width: Int(w), height: Int(h), pixelWidth: Int(w) * 2,
                                pixelHeight: Int(h) * 2, hz: refresh)
        let actual = DisplayIO.currentMode(id)!
        NSLog("hidipi: initial virtual mode from macOS: %@", Modes.describe(actual))
        // virtual.mode_matches: hz may be briefly missing during startup; that must not
        // take down the virtual display.
        if !Modes.modeMatchesLenient(actual, expected) {
            let wanted = try Modes.chooseMode(DisplayIO.allModes(id).map(DisplayIO.info),
                                              size: (Int(w), Int(h)), current: actual, refresh: refresh)
            try service.setMode(id, expected: wanted)
        }
        try service.waitUntil(timeout: 5, "Virtual display created, but macOS did not provide the requested HiDPI mode") {
            Modes.modeMatchesLenient(DisplayIO.currentMode(id), expected)
        }
        return id
    }
    #else
    func start(size: (Int, Int), refresh: Double) throws -> CGDirectDisplayID {
        throw HiDPIError("Virtual displays are supported on Apple Silicon.")
    }
    #endif

    /// virtual.close: release the reference (dealloc tears it down) and wait for offline.
    func close() {
        display = nil
        guard displayID != 0 else { return }
        let id = displayID
        displayID = 0
        try? service.waitUntil(timeout: 8, "The virtual display did not go away in time; it will be released when the process exits") {
            !DisplayIO.isOnline(id)
        }
    }
}

enum VirtualDisplay {
    /// virtual.capture_original: filter out macOS's transient fallback desktop (unkn/virt);
    /// never treat it as EDID hardware to replay. An empty result is the headless case.
    static func captureOriginal(_ service: DisplayService) throws -> DisplayState {
        let stable = try service.snapshot(allowEmpty: true).displays.filter {
            !($0.vendor == 0x756E6B6E && $0.model == 0x76697274)
        }
        return DisplayState(displays: stable)
    }
}
