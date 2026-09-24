/// 移植 virtual.py：CGVirtualDisplay 私有接口的纯 Swift 桥接与生命周期。
///
/// 本机已实证：CGVirtualDisplay* 类存在于运行时，但未声明我们的协议，
/// `as!` 下转失败；`unsafeBitCast` 到 @objc 协议存在体（单指针布局）可正常派发
/// setter/getter。alloc/init 家族改用显式 objc_msgSend + Unmanaged：
/// alloc 不认领（+1 由 init 吞掉），init 结果 takeRetainedValue 恰好一次——
/// 与 ObjC ARC 等价。之前 perform(alloc)+perform(init) 双 takeRetainedValue
/// 造成过度释放，在 GUI 事件循环排 autorelease pool 时崩溃。
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

    // —— 显式 objc_msgSend 桥（所有权与 ObjC ARC 等价，避免 perform/协议 init
    //     家族的两次 takeRetainedValue 双认领导致过度释放崩溃）——
    private typealias AllocFn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
    private typealias InitFn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
    private typealias InitWithDescriptorFn =
        @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>
    private typealias InitModeFn =
        @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>

    private static func classObject(_ className: String) throws -> AnyObject {
        guard let anyClass: AnyObject = NSClassFromString(className) else {
            throw HiDPIError("当前 macOS 缺少 \(className)；虚拟屏幕接口不可用。")
        }
        return anyClass
    }

    /// objc_msgSend 在 Swift 中标记为不可用（变参形式），经 dlsym 取原始地址。
    private static func rawMsgSend() -> UnsafeMutableRawPointer {
        if let symbol = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend") { return symbol }
        fatalError("objc_msgSend 不可用")
    }

    /// alloc 不认领（+1 由 init 家族吞掉）；init 结果 takeRetainedValue 认领一次。
    private static func alloc(_ className: String) throws -> AnyObject {
        let fn = unsafeBitCast(rawMsgSend(), to: AllocFn.self)
        return fn(try classObject(className), sel_registerName("alloc")).takeUnretainedValue()
    }

    /// 普通对象（descriptor/settings 等）：alloc + init。
    /// init 必不可少：未 init 的对象内部存储为 nil，setter 会静默失效。
    static func instantiate(_ className: String) throws -> NSObject {
        let fn = unsafeBitCast(rawMsgSend(), to: InitFn.self)
        let initialized = fn(try alloc(className), sel_registerName("init"))
        guard let object = initialized.takeRetainedValue() as? NSObject else {
            throw HiDPIError("无法初始化 \(className)")
        }
        return object
    }

    /// CGVirtualDisplayMode：initWithWidth:height:refreshRate:。
    static func makeMode(width: UInt32, height: UInt32, refreshRate: Double) throws -> AnyObject {
        let fn = unsafeBitCast(rawMsgSend(), to: InitModeFn.self)
        return fn(try alloc("CGVirtualDisplayMode"),
                  sel_registerName("initWithWidth:height:refreshRate:"),
                  width, height, refreshRate).takeRetainedValue()
    }

    /// CGVirtualDisplay：initWithDescriptor:。
    static func makeDisplay(descriptor: AnyObject) throws -> AnyObject {
        let fn = unsafeBitCast(rawMsgSend(), to: InitWithDescriptorFn.self)
        return fn(try alloc("CGVirtualDisplay"),
                  sel_registerName("initWithDescriptor:"),
                  descriptor).takeRetainedValue()
    }
}

/// virtual.VirtualDisplay：持有强引用即持有虚拟屏；释放引用即拆除。
final class VirtualDisplayController {
    private let service: DisplayService
    private var display: AnyObject?
    private(set) var displayID: CGDirectDisplayID = 0

    init(service: DisplayService) { self.service = service }

    #if arch(arm64)
    /// virtual.validate_options 的约束。
    static func validateOptions(size: (Int, Int), refresh: Double) throws {
        guard refresh.isFinite, (24...120).contains(refresh) else {
            throw HiDPIError("虚拟屏幕刷新率必须在 24–120 Hz 之间。")
        }
        guard max(size.0, size.1) <= 3840, size.0 * size.1 <= 8_294_400 else {
            throw HiDPIError("虚拟屏幕逻辑尺寸最大为 3840×2160（或等像素数竖屏）。")
        }
    }

    /// virtual.VirtualDisplay.start：创建 → 应用模式 → 等待上线 → 核验。
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
        guard id != 0 else { throw HiDPIError("macOS 拒绝创建虚拟屏幕。请在已登录的桌面会话运行。") }
        displayID = id
        NSLog("hidipi: 已创建虚拟屏幕对象，ID=%u，等待模式就绪。", id)

        let settings = try VirtualBridge.instantiate("CGVirtualDisplaySettings")
        let s = unsafeBitCast(settings, to: CGVirtualDisplaySettingsProto.self)
        s.setHiDPI(1)
        // HiDPI 开启时，模式尺寸即逻辑点数。
        let mode = try VirtualBridge.makeMode(width: w, height: h, refreshRate: refresh)
        s.setModes(NSArray(object: mode))
        guard proto.applySettings(settings) else {
            throw HiDPIError("macOS 拒绝应用虚拟屏幕模式。")
        }

        try service.waitUntil(timeout: 10, "虚拟屏幕未及时上线") {
            try DisplayIO.onlineIDs().contains(id) && DisplayIO.currentMode(id) != nil
        }
        let expected = ModeInfo(width: Int(w), height: Int(h), pixelWidth: Int(w) * 2,
                                pixelHeight: Int(h) * 2, hz: refresh)
        let actual = DisplayIO.currentMode(id)!
        NSLog("hidipi: macOS 初始虚拟模式：%@", Modes.describe(actual))
        // virtual.mode_matches：启动期 hz 可能暂缺，不应因此终止虚拟屏。
        if !Modes.modeMatchesLenient(actual, expected) {
            let wanted = try Modes.chooseMode(DisplayIO.allModes(id).map(DisplayIO.info),
                                              size: (Int(w), Int(h)), current: actual, refresh: refresh)
            try service.setMode(id, expected: wanted)
        }
        try service.waitUntil(timeout: 5, "虚拟屏幕已创建，但 macOS 未提供要求的 HiDPI 模式") {
            Modes.modeMatchesLenient(DisplayIO.currentMode(id), expected)
        }
        return id
    }
    #else
    func start(size: (Int, Int), refresh: Double) throws -> CGDirectDisplayID {
        throw HiDPIError("虚拟屏幕目前支持 Apple Silicon。")
    }
    #endif

    /// virtual.close：释放引用（dealloc 拆除），等待下线。
    func close() {
        display = nil
        guard displayID != 0 else { return }
        let id = displayID
        displayID = 0
        try? service.waitUntil(timeout: 8, "虚拟屏幕未及时移除；进程退出后将释放") {
            try !DisplayIO.onlineIDs().contains(id)
        }
    }
}

enum VirtualDisplay {
    /// virtual.capture_original：过滤 macOS 的瞬态兜底桌面（unkn/virt），绝不当作 EDID 硬件回放。
    static func captureOriginal(_ service: DisplayService) throws -> BackupSnapshot {
        let original = try service.snapshot(allowEmpty: true)
        let transient = original.displays.filter {
            $0.vendor == 0x756E6B6E && $0.model == 0x76697274
        }
        let stable = original.displays.filter { !transient.contains($0) }
        if stable.isEmpty {
            return BackupSnapshot(headlessCreated: original.created, macos: original.macos,
                                  systemFallback: transient)
        }
        var partial = original
        partial.displays = stable
        return partial
    }
}
