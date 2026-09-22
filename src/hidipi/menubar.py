"""Best-effort menu-bar status item shown while hidipi controls displays.

Pure ctypes bindings, loaded lazily; importing this module loads no frameworks.
The icon is cosmetic: any failure degrades to "no icon" and never affects
display switching or rollback. Unlike macos.ObjC this bridge is not gated on
arm64 so Intel Macs get the icon for physical-display sessions too.
"""
import ctypes as C
import importlib.resources
import os
import sys

from . import errors
from .macos import P, Pair, bind

VARIABLE_LENGTH = -1.0   # NSVariableStatusItemLength
ACCESSORY_POLICY = 1     # NSApplicationActivationPolicyAccessory: no Dock icon
ICON_POINTS = 18.0       # Logical icon size per assets/README.md
ASSET_NAMES = ('StatusIconTemplate.png', 'StatusIconTemplate@2x.png',
               'StatusIconTemplate@3x.png')
TARGET_CLASS = b'HIDIPiStatusTarget'
ACTION_SELECTOR = 'hidipiRestore:'
RESTORE_LABEL = '恢复原始设置并退出'


class _Bridge:
    """objc_msgSend bridge with a runtime-created menu target class."""

    def __init__(self):
        self.runtime = C.CDLL('/usr/lib/libobjc.A.dylib')
        C.CDLL('/System/Library/Frameworks/Foundation.framework/Foundation')
        C.CDLL('/System/Library/Frameworks/AppKit.framework/AppKit')
        for name, signature in {
            'objc_getClass': (P, C.c_char_p),
            'sel_registerName': (P, C.c_char_p),
            'objc_allocateClassPair': (P, P, C.c_char_p, C.c_size_t),
            'class_addMethod': (C.c_bool, P, P, P, C.c_char_p),
            'objc_registerClassPair': (None, P),
        }.items():
            bind(self.runtime, name, *signature)
        self.address = C.cast(self.runtime.objc_msgSend, P).value
        self.functions = {}

    def cls(self, name):
        result = self.runtime.objc_getClass(name.encode())
        if not result:
            raise errors.HiDPIError(f'当前 macOS 缺少 {name}；状态栏图标不可用。')
        return result

    def sel(self, name):
        return self.runtime.sel_registerName(name.encode())

    def send(self, receiver, selector, result=P, types=(), values=()):
        sel = self.sel(selector)
        signature = (result, tuple(types))
        if signature not in self.functions:
            self.functions[signature] = C.CFUNCTYPE(result, P, P, *types)(self.address)
        if selector != 'respondsToSelector:' and not self.send(
                receiver, 'respondsToSelector:', C.c_bool, (P,), (sel,)):
            raise errors.HiDPIError(f'macOS 不支持状态栏接口 {selector}')
        return self.functions[signature](receiver, sel, *values)

    def new(self, name):
        obj = self.send(self.send(self.cls(name), 'alloc'), 'init')
        if not obj:
            raise errors.HiDPIError(f'无法初始化 {name}')
        return obj

    def release(self, obj):
        if obj:
            self.send(obj, 'release', None)

    def string(self, text):
        return self.send(self.cls('NSString'), 'stringWithUTF8String:', P,
                         (C.c_char_p,), (text.encode(),))


def _asset_paths():
    root = importlib.resources.files(__package__).joinpath('assets')
    # Resolve real paths while reading, so zipped installs also work.
    with importlib.resources.as_file(root) as folder:
        return [str(folder / name) for name in ASSET_NAMES]


def _bridge():
    return _Bridge()


class _Controller:
    def __init__(self, bridge, status, on_restore):
        self.bridge = bridge
        self.on_restore = on_restore
        self.item = self.menu = self.image = self.target = None
        b = bridge
        self.pool = b.new('NSAutoreleasePool')
        # Accessory policy keeps the agent out of the Dock even if this runs
        # before macos.hide_dock_icon().
        app = b.send(b.cls('NSApplication'), 'sharedApplication')
        b.send(app, 'setActivationPolicy:', None, (C.c_long,), (ACCESSORY_POLICY,))
        self.item = b.send(b.send(b.cls('NSStatusBar'), 'systemStatusBar'),
                           'statusItemWithLength:', P, (C.c_double,), (VARIABLE_LENGTH,))
        if not self.item:
            raise errors.HiDPIError('系统未提供状态栏项。')
        self.menu = b.new('NSMenu')
        self.image = self._load_icon()
        button = b.send(self.item, 'button')
        b.send(button, 'setImage:', None, (P,), (self.image,))
        b.send(button, 'setToolTip:', None, (P,), (b.string('hidipi'),))
        b.send(button, 'setAccessibilityLabel:', None, (P,), (b.string('hidipi'),))
        self._build_menu(status)
        b.send(self.item, 'setMenu:', None, (P,), (self.menu,))

    def _load_icon(self):
        b = self.bridge
        image = b.send(b.send(b.cls('NSImage'), 'alloc'), 'initWithSize:', P,
                       (Pair,), (Pair(ICON_POINTS, ICON_POINTS),))
        if not image:
            raise errors.HiDPIError('无法创建状态栏图像。')
        for path in _asset_paths():
            rep = b.send(b.cls('NSBitmapImageRep'), 'imageRepWithContentsOfFile:',
                         P, (P,), (b.string(path),))
            if not rep:
                continue
            # Marking the point size lets AppKit pick @2x/@3x by pixel count.
            b.send(rep, 'setSize:', None, (Pair,), (Pair(ICON_POINTS, ICON_POINTS),))
            b.send(image, 'addRepresentation:', None, (P,), (rep,))
        b.send(image, 'setTemplate:', None, (C.c_bool,), (True,))
        return image

    def _add_item(self, title, action=0):
        return self.bridge.send(self.menu, 'addItemWithTitle:action:keyEquivalent:', P,
                                (P, P, P), (self.bridge.string(title), action,
                                            self.bridge.string('')))

    def _build_menu(self, status):
        b = self.bridge
        b.send(self._add_item(status), 'setEnabled:', None, (C.c_bool,), (False,))
        b.send(self.menu, 'addItem:', None, (P,),
               (b.send(b.cls('NSMenuItem'), 'separatorItem'),))
        quit_item = self._add_item(RESTORE_LABEL, b.sel(ACTION_SELECTOR))
        self.target = self._make_target()
        b.send(quit_item, 'setTarget:', None, (P,), (self.target,))

    def _make_target(self):
        """Register an NSObject subclass whose action calls back into Python."""
        b = self.bridge
        created = b.runtime.objc_allocateClassPair(b.cls('NSObject'), TARGET_CLASS, 0)
        if not created:
            # A second controller in one process: reuse the registered class.
            created = b.cls(TARGET_CLASS.decode())
        def invoke(_self, _cmd, _sender):
            try:
                self.restore()
            except Exception:
                pass  # Never let Python errors cross into ObjC.
        # Keep a reference: the IMP must outlive every menu item.
        self._imp = C.CFUNCTYPE(None, P, P, P)(invoke)
        if not b.runtime.class_addMethod(created, b.sel(ACTION_SELECTOR),
                                         C.cast(self._imp, P), b'v@:@'):
            raise errors.HiDPIError('无法注册状态栏菜单动作。')
        b.runtime.objc_registerClassPair(created)
        target = b.send(b.send(created, 'alloc'), 'init')
        if not target:
            raise errors.HiDPIError('无法初始化状态栏菜单目标。')
        return target

    def restore(self):
        """Menu action: same path as Ctrl+C — preview loop exits and rolls back."""
        self.on_restore()

    def close(self):
        b = self.bridge
        try:
            b.send(b.send(b.cls('NSStatusBar'), 'systemStatusBar'),
                   'removeStatusItem:', None, (P,), (self.item,))
        finally:
            for name in ('image', 'menu', 'target', 'item'):
                b.release(getattr(self, name, None))
                setattr(self, name, None)
            b.release(self.pool)


def start(status, on_restore):
    """Show the menu-bar icon; returns a controller or None (best effort)."""
    if sys.platform != 'darwin' or os.environ.get('HIDIPI_MENUBAR') == '0':
        return None
    try:
        return _Controller(_bridge(), status, on_restore)
    except Exception:
        return None


def stop(controller):
    if controller is not None:
        try:
            controller.close()
        except Exception:
            pass
