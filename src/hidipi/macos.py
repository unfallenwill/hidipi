"""macOS native bindings. Importing this module does not load frameworks."""
import contextlib
import ctypes as C
import datetime
import platform
import sys
import time
from . import errors, modes as display_modes

P = C.c_void_p
U = C.c_uint32
I = C.c_int32
D = C.c_double


class Pair(C.Structure):
    _fields_ = [("x", D), ("y", D)]


class Rect(C.Structure):
    _fields_ = [("origin", Pair), ("size", Pair)]


class ProcessSerialNumber(C.Structure):
    _fields_ = [("high", U), ("low", U)]


def check(code, operation):
    if code:
        raise errors.HiDPIError(f"{operation} 失败，CoreGraphics 错误码 {code}")


def bind(lib, name, result, *args):
    fn = getattr(lib, name)
    fn.restype, fn.argtypes = result, args
    return fn


class Mac:
    def __init__(self):
        if sys.platform != "darwin":
            raise errors.HiDPIError("此工具仅支持 macOS。")
        self.cg = C.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        self.cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        g, f = self.cg, self.cf
        signatures = {
            "CGGetOnlineDisplayList": (I, U, C.POINTER(U), C.POINTER(U)),
            "CGDisplayCopyDisplayMode": (P, U),
            "CGDisplayCopyAllDisplayModes": (P, U, P),
            "CGDisplayModeGetWidth": (C.c_size_t, P),
            "CGDisplayModeGetHeight": (C.c_size_t, P),
            "CGDisplayModeGetPixelWidth": (C.c_size_t, P),
            "CGDisplayModeGetPixelHeight": (C.c_size_t, P),
            "CGDisplayModeGetRefreshRate": (D, P),
            "CGDisplayModeGetIODisplayModeID": (U, P),
            "CGDisplayModeGetIOFlags": (U, P),
            "CGDisplayModeIsUsableForDesktopGUI": (C.c_bool, P),
            "CGDisplayBounds": (Rect, U),
            "CGDisplayScreenSize": (Pair, U),
            "CGDisplayVendorNumber": (U, U),
            "CGDisplayModelNumber": (U, U),
            "CGDisplaySerialNumber": (U, U),
            "CGDisplayIsBuiltin": (U, U),
            "CGDisplayIsMain": (U, U),
            "CGDisplayMirrorsDisplay": (U, U),
            "CGDisplayIsInMirrorSet": (U, U),
            "CGBeginDisplayConfiguration": (I, C.POINTER(P)),
            "CGCancelDisplayConfiguration": (I, P),
            "CGCompleteDisplayConfiguration": (I, P, U),
            "CGConfigureDisplayWithDisplayMode": (I, P, U, P, P),
            "CGConfigureDisplayMirrorOfDisplay": (I, P, U, U),
            "CGConfigureDisplayOrigin": (I, P, U, I, I),
        }
        for name, signature in signatures.items():
            bind(g, name, *signature)
        # macOS 27 no longer exports this symbol from CoreGraphics directly.
        try:
            self.display_uuid = bind(g, 'CGDisplayCreateUUIDFromDisplayID', P, U)
        except AttributeError:
            self.sl = C.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
            try:
                self.display_uuid = bind(self.sl, 'CGDisplayCreateUUIDFromDisplayID', P, U)
            except AttributeError:
                raise errors.HiDPIError('当前 macOS 未提供显示器 UUID 接口，无法可靠备份。') from None
        bind(f, "CFRelease", None, P)
        bind(f, "CFRetain", P, P)
        bind(f, "CFArrayGetCount", C.c_long, P)
        bind(f, "CFArrayGetValueAtIndex", P, P, C.c_long)
        bind(f, "CFDictionaryCreate", P, P, C.POINTER(P), C.POINTER(P), C.c_long, P, P)
        bind(f, "CFUUIDCreateString", P, P, P)
        bind(f, "CFStringGetCString", C.c_bool, P, P, C.c_long, U)
        bind(f, "CFRunLoopRunInMode", I, P, D, C.c_bool)
        self.run_mode = P.in_dll(f, "kCFRunLoopDefaultMode")

    def pump(self, seconds=0.1):
        self.cf.CFRunLoopRunInMode(self.run_mode, seconds, False)
        # An empty run loop may return immediately.
        time.sleep(min(seconds, 0.05))

    def ids(self):
        ids, count = (U * 128)(), U()
        check(self.cg.CGGetOnlineDisplayList(128, ids, C.byref(count)), "读取显示器")
        return list(ids)[:count.value]

    def info(self, ptr):
        if not ptr:
            return None
        g = self.cg
        return dict(width=int(g.CGDisplayModeGetWidth(ptr)),
                    height=int(g.CGDisplayModeGetHeight(ptr)),
                    pixel_width=int(g.CGDisplayModeGetPixelWidth(ptr)),
                    pixel_height=int(g.CGDisplayModeGetPixelHeight(ptr)),
                    hz=g.CGDisplayModeGetRefreshRate(ptr),
                    mode_id=int(g.CGDisplayModeGetIODisplayModeID(ptr)),
                    flags=int(g.CGDisplayModeGetIOFlags(ptr)),
                    usable=bool(g.CGDisplayModeIsUsableForDesktopGUI(ptr)))

    def current(self, display):
        ptr = self.cg.CGDisplayCopyDisplayMode(display)
        try:
            if not ptr and self.cg.CGDisplayVendorNumber(display) == 0xF0F0:
                return screen_mode(display)
            return self.info(ptr)
        finally:
            if ptr:
                self.cf.CFRelease(ptr)

    @contextlib.contextmanager
    def modes(self, display):
        keys = (P * 1)(P.in_dll(self.cg, "kCGDisplayShowDuplicateLowResolutionModes"))
        vals = (P * 1)(P.in_dll(self.cf, "kCFBooleanTrue"))
        options = self.cf.CFDictionaryCreate(None, keys, vals, 1, None, None)
        array = self.cg.CGDisplayCopyAllDisplayModes(display, options)
        self.cf.CFRelease(options)
        try:
            yield ([] if not array else [self.cf.CFArrayGetValueAtIndex(array, i)
                   for i in range(self.cf.CFArrayGetCount(array))])
        finally:
            if array:
                self.cf.CFRelease(array)

    def identity(self, display):
        value = self.display_uuid(display)
        if not value:
            raise errors.HiDPIError(f"无法取得显示器 {display} 的 UUID；不能可靠备份。")
        string = self.cf.CFUUIDCreateString(None, value)
        try:
            buf = C.create_string_buffer(128)
            if not self.cf.CFStringGetCString(string, buf, len(buf), 0x08000100):
                raise errors.HiDPIError("无法解码显示器 UUID")
            return buf.value.decode()
        finally:
            self.cf.CFRelease(string)
            self.cf.CFRelease(value)

    def snapshot(self, allow_empty=False):
        displays = []
        for display in self.ids():
            bounds = self.cg.CGDisplayBounds(display)
            size = self.cg.CGDisplayScreenSize(display)
            displays.append(dict(id=display, uuid=self.identity(display),
                vendor=self.cg.CGDisplayVendorNumber(display),
                model=self.cg.CGDisplayModelNumber(display),
                serial=self.cg.CGDisplaySerialNumber(display),
                builtin=bool(self.cg.CGDisplayIsBuiltin(display)),
                main=bool(self.cg.CGDisplayIsMain(display)),
                mirror_of=int(self.cg.CGDisplayMirrorsDisplay(display)),
                in_mirror_set=bool(self.cg.CGDisplayIsInMirrorSet(display)),
                origin=[int(bounds.origin.x), int(bounds.origin.y)],
                millimeters=[size.x, size.y], mode=self.current(display)))
        if not displays and not allow_empty:
            raise errors.HiDPIError("未读取到在线显示器。请在已登录桌面的本机终端运行；沙箱/SSH 会话可能无法访问 WindowServer。")
        if not displays:
            return dict(schema=2, headless=True, displays=[],
                        created=datetime.datetime.now().astimezone().isoformat(), macos=platform.mac_ver()[0])
        return dict(schema=1, created=datetime.datetime.now().astimezone().isoformat(),
                    macos=platform.mac_ver()[0], displays=displays)

    @contextlib.contextmanager
    def transaction(self, scope=0):
        config = P()
        check(self.cg.CGBeginDisplayConfiguration(C.byref(config)), "开始显示配置")
        try:
            yield config
        except BaseException:
            self.cg.CGCancelDisplayConfiguration(config)
            raise
        else:
            check(self.cg.CGCompleteDisplayConfiguration(config, scope), "应用显示配置")

    def set_mode(self, display, expected):
        with self.modes(display) as modes:
            candidates = [m for m in modes if display_modes.mode_matches(self.info(m), expected)]
            if not candidates:
                raise errors.HiDPIError("指定模式已不可用；尚未切换。")
            with self.transaction() as config:
                check(self.cg.CGConfigureDisplayWithDisplayMode(
                    config, display, candidates[0], None), "切换 HiDPI")

    def restore(self, snapshot):
        """Resolve by UUID, preflight every mode, then commit as one transaction."""
        if snapshot.get('schema') == 2 and snapshot.get('headless') is True and not snapshot['displays']:
            return
        live = {self.identity(d): d for d in self.ids()}
        mapping = {}
        retained = []
        try:
            for saved in snapshot["displays"]:
                display = live.get(saved["uuid"])
                if display is None:
                    raise errors.HiDPIError(f'备份中的显示器 {saved["uuid"]} 未连接；请重新连接后恢复。')
                mode = saved["mode"]
                if not mode:
                    raise errors.HiDPIError("备份缺少原始模式，无法完整恢复。")
                with self.modes(display) as modes:
                    matches = [m for m in modes if display_modes.mode_matches(self.info(m), mode)]
                    if not matches:
                        raise errors.HiDPIError(f'显示器 {display} 的原始模式当前不可用：{display_modes.describe(mode)}')
                    # IDs are only a tie-breaker: they can change across reboots.
                    matches.sort(key=lambda m: self.info(m)["mode_id"] != mode["mode_id"])
                    ptr = self.cf.CFRetain(matches[0])
                    retained.append(ptr)
                    mapping[saved["id"]] = (display, ptr, saved)
            with self.transaction(scope=1) as config:
                for display, ptr, saved in mapping.values():
                    check(self.cg.CGConfigureDisplayMirrorOfDisplay(config, display, 0), "解除镜像")
                for display, ptr, saved in mapping.values():
                    check(self.cg.CGConfigureDisplayWithDisplayMode(config, display, ptr, None), "恢复原始模式")
                    if not saved["mirror_of"]:
                        check(self.cg.CGConfigureDisplayOrigin(config, display, *saved["origin"]), "恢复屏幕排列")
                for display, ptr, saved in mapping.values():
                    if saved["mirror_of"]:
                        source = mapping.get(saved["mirror_of"])
                        if not source:
                            raise errors.HiDPIError("备份中的镜像源不完整。")
                        check(self.cg.CGConfigureDisplayMirrorOfDisplay(config, display, source[0]), "恢复原镜像")
            self.wait_until(lambda: all(
                display_modes.mode_matches(self.current(d), s["mode"]) and
                self.cg.CGDisplayMirrorsDisplay(d) == (
                    mapping[s["mirror_of"]][0] if s["mirror_of"] else 0) and
                (s["mirror_of"] or [int(self.cg.CGDisplayBounds(d).origin.x),
                                      int(self.cg.CGDisplayBounds(d).origin.y)] == s["origin"])
                for d, _, s in mapping.values()), "恢复后的分辨率或排列未通过核验", 6)
        finally:
            for ptr in retained:
                self.cf.CFRelease(ptr)

    def wait_until(self, predicate, error, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            self.pump()
        raise errors.HiDPIError(error)


def hide_dock_icon():
    # Registering with WindowServer (virtual display creation, display modes)
    # makes a launchd-run Python appear in the Dock. Demote to a UI element:
    # no Dock icon, no menu bar, display work unaffected. Must run after the
    # trigger, or the later registration re-promotes the process. Cosmetic on
    # failure, so loading errors and native error returns are ignored.
    # Native aborts cannot be caught by Python: this requires desktop access.
    # Unit tests mock this API; native smoke tests run in a separate process.
    try:
        hiservices = C.CDLL('/System/Library/Frameworks/ApplicationServices'
                            '.framework/Frameworks/HIServices.framework/HIServices')
        transform = bind(hiservices, 'TransformProcessType', I,
                         C.POINTER(ProcessSerialNumber), U)
    except (OSError, AttributeError):
        return
    psn = ProcessSerialNumber(0, 2)  # kCurrentProcess
    transform(C.byref(psn), 4)  # kProcessTransformToUIElement


class ObjC:
    def __init__(self):
        if platform.machine() != 'arm64':
            raise errors.HiDPIError('虚拟屏幕目前支持 Apple Silicon，请使用原生 ARM64 Python。')
        self.foundation = C.CDLL('/System/Library/Frameworks/Foundation.framework/Foundation')
        self.runtime = C.CDLL('/usr/lib/libobjc.A.dylib')
        self.libsystem = C.CDLL('/usr/lib/libSystem.B.dylib')
        bind(self.runtime, 'objc_getClass', P, C.c_char_p)
        bind(self.runtime, 'sel_registerName', P, C.c_char_p)
        bind(self.libsystem, 'dispatch_get_global_queue', P, C.c_long, C.c_ulong)
        self.address = C.cast(self.runtime.objc_msgSend, P).value
        self.functions = {}

    def cls(self, name):
        result = self.runtime.objc_getClass(name.encode())
        if not result:
            raise errors.HiDPIError(f'当前 macOS 缺少 {name}；虚拟屏幕接口不可用。')
        return result

    def send(self, receiver, selector, result=P, types=(), values=()):
        sel = self.runtime.sel_registerName(selector.encode())
        signature = (result, tuple(types))
        if signature not in self.functions:
            self.functions[signature] = C.CFUNCTYPE(result, P, P, *types)(self.address)
        if selector != 'respondsToSelector:' and not self.send(
                receiver, 'respondsToSelector:', C.c_bool, (P,), (sel,)):
            raise errors.HiDPIError(f'macOS 不支持虚拟屏幕接口 {selector}')
        return self.functions[signature](receiver, sel, *values)

    def new(self, name):
        obj = self.send(self.send(self.cls(name), 'alloc'), 'init')
        if not obj:
            raise errors.HiDPIError(f'无法初始化 {name}')
        return obj

    def release(self, obj):
        if obj:
            self.send(obj, 'release', None)


def screen_mode(display_id):
    """Some headless sessions expose NSScreen backing data but no CG display_modes."""
    appkit = C.CDLL('/System/Library/Frameworks/AppKit.framework/AppKit')
    objc = ObjC()
    pool = objc.new('NSAutoreleasePool')
    try:
        screens = objc.send(objc.cls('NSScreen'), 'screens')
        key = objc.send(objc.cls('NSString'), 'stringWithUTF8String:', P,
                        (C.c_char_p,), (b'NSScreenNumber',))
        for index in range(objc.send(screens, 'count', C.c_ulong)):
            screen = objc.send(screens, 'objectAtIndex:', P, (C.c_ulong,), (index,))
            info = objc.send(screen, 'deviceDescription')
            number = objc.send(info, 'objectForKey:', P, (P,), (key,))
            if objc.send(number, 'unsignedIntValue', U) != display_id:
                continue
            frame = objc.send(screen, 'frame', Rect)
            scale = objc.send(screen, 'backingScaleFactor', D)
            w, h = round(frame.size.x), round(frame.size.y)
            return dict(width=w, height=h, pixel_width=round(w*scale), pixel_height=round(h*scale),
                        hz=0, mode_id=0, flags=0, usable=True, source='NSScreen', backing_scale=scale)
        return None
    finally:
        objc.release(pool)
