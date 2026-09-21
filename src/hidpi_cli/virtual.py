"""Virtual-display creation and cleanup workflows."""
import ctypes as C
import math
from . import backup as backups, errors, macos, modes as display_modes, runtime


def mode_matches(actual, expected):
    # During startup CG can expose only NSScreen data (Hz unknown), then later
    # publish a complete mode. That transition must not terminate the display.
    if not actual:
        return False
    rate = actual['hz'] if actual['hz'] and expected['hz'] else 0
    return display_modes.mode_matches(dict(actual, hz=rate),
                            dict(expected, hz=expected['hz'] if rate else 0))


class VirtualDisplay:
    VENDOR = 0xF0F0

    def __init__(self, mac, size, refresh=60):
        self.mac, self.size, self.refresh = mac, size, refresh
        self.objc = macos.ObjC()
        self.owned = []
        self.display = None
        self.display_id = 0

    def own(self, name):
        obj = self.objc.new(name)
        self.owned.append(obj)
        return obj

    def start(self):
        o = self.objc
        w, h = self.size
        self.own('NSAutoreleasePool')
        descriptor = self.own('CGVirtualDisplayDescriptor')
        name = o.send(o.cls('NSString'), 'stringWithUTF8String:', macos.P,
                      (C.c_char_p,), (b'HiDPI Virtual Display',))
        properties = [
            ('Name', macos.P, name),
            ('Queue', macos.P, o.libsystem.dispatch_get_global_queue(0, 0)),
            ('MaxPixelsWide', macos.U, w * 2), ('MaxPixelsHigh', macos.U, h * 2),
            ('SizeInMillimeters', macos.Pair, macos.Pair(w * 25.4 / 110, h * 25.4 / 110)),
            ('VendorID', macos.U, self.VENDOR),
            ('ProductID', macos.U, 1 + ((w * 31 + h) % 65534)),
            ('SerialNum', macos.U, 1), ('SerialNumber', macos.U, 1),
            ('RedPrimary', macos.Pair, macos.Pair(0.64, 0.33)),
            ('GreenPrimary', macos.Pair, macos.Pair(0.30, 0.60)),
            ('BluePrimary', macos.Pair, macos.Pair(0.15, 0.06)),
            ('WhitePoint', macos.Pair, macos.Pair(0.3127, 0.3290)),
        ]
        for name, kind, value in properties:
            o.send(descriptor, f'set{name}:', None, (kind,), (value,))
        self.display = o.send(o.send(o.cls('CGVirtualDisplay'), 'alloc'),
                              'initWithDescriptor:', macos.P, (macos.P,), (descriptor,))
        if not self.display:
            raise errors.HiDPIError('macOS 拒绝创建虚拟屏幕。请在已登录的桌面会话运行。')
        self.display_id = o.send(self.display, 'displayID', macos.U)
        print(f'已创建虚拟屏幕对象，ID={self.display_id}，等待模式就绪。', flush=True)
        settings = self.own('CGVirtualDisplaySettings')
        o.send(settings, 'setHiDPI:', None, (macos.U,), (1,))
        modes = self.own('NSMutableArray')
        # With hiDPI enabled, the declared mode dimensions are logical points.
        for width, height in ((w, h),):
            mode = o.send(o.send(o.cls('CGVirtualDisplayMode'), 'alloc'),
                'initWithWidth:height:refreshRate:', macos.P,
                (macos.U, macos.U, macos.D), (width, height, self.refresh))
            if not mode:
                raise errors.HiDPIError('无法创建虚拟屏幕模式。')
            try:
                o.send(modes, 'addObject:', None, (macos.P,), (mode,))
            finally:
                o.release(mode)
        o.send(settings, 'setModes:', None, (macos.P,), (modes,))
        if not o.send(self.display, 'applySettings:', C.c_bool, (macos.P,), (settings,)):
            raise errors.HiDPIError('macOS 拒绝应用虚拟屏幕模式。')
        try:
            self.mac.wait_until(lambda: self.display_id in self.mac.ids() and
                                self.mac.current(self.display_id), '虚拟屏幕未及时上线', 10)
        except errors.HiDPIError:
            print(f'诊断：在线屏幕 {self.mac.ids()}；虚拟屏幕当前模式 '
                  f'{self.mac.current(self.display_id)}', flush=True)
            with self.mac.modes(self.display_id) as pointers:
                print('诊断：可用模式 ' + repr([self.mac.info(p) for p in pointers]), flush=True)
            bounds = self.mac.cg.CGDisplayBounds(self.display_id)
            print(f'诊断：桌面尺寸 {bounds.size.x}×{bounds.size.y}', flush=True)
            raise
        expected = dict(width=w, height=h, pixel_width=2*w, pixel_height=2*h, hz=self.refresh)
        actual = self.mac.current(self.display_id)
        print('macOS 初始虚拟模式：' + display_modes.describe(actual), flush=True)
        if actual.get('source') == 'NSScreen':
            print(f'已通过 NSScreen 核验倍率；请求刷新率 {self.refresh:g} Hz，系统未报告实际刷新率。', flush=True)
        if not mode_matches(actual, expected):
            with self.mac.modes(self.display_id) as pointers:
                wanted = display_modes.choose_mode([self.mac.info(p) for p in pointers],
                                        self.size, actual, self.refresh)
            self.mac.set_mode(self.display_id, wanted)
        self.mac.wait_until(lambda: mode_matches(self.mac.current(self.display_id), expected),
                            '虚拟屏幕已创建，但 macOS 未提供要求的 HiDPI 模式', 5)
        return self.display_id

    def close(self):
        try:
            self.objc.release(self.display)
            self.display = None
        finally:
            while self.owned:
                self.objc.release(self.owned.pop())
        if self.display_id:
            self.mac.wait_until(lambda: self.display_id not in self.mac.ids(),
                                '虚拟屏幕未及时移除；进程退出后将释放', 8)


def validate_options(args):
    if not math.isfinite(args.refresh) or not 24 <= args.refresh <= 120:
        raise errors.HiDPIError('虚拟屏幕刷新率必须在 24–120 Hz 之间。')
    if max(args.size) > 3840 or args.size[0] * args.size[1] > 8_294_400:
        raise errors.HiDPIError('虚拟屏幕逻辑尺寸最大为 3840×2160（或等像素数竖屏）。')
    if not 5 <= args.seconds <= 120:
        raise errors.HiDPIError('预览时间必须在 5–120 秒之间。')


def add_parser(sub):
    parser = sub.add_parser('virtual', help='创建不需要实体屏幕的 HiDPI 虚拟屏幕')
    parser.add_argument('--size', type=display_modes.size_value, default=(1920, 1080), help='逻辑尺寸，默认 1920x1080')
    parser.add_argument('--refresh', type=float, default=60, help='虚拟刷新率，默认 60 Hz')
    parser.add_argument('--seconds', type=int, default=20, help='预览秒数，默认 20')
    parser.add_argument('--keep', action='store_true', help='持续运行，Ctrl+C 移除虚拟屏幕')


def restore_connected(mac, original):
    live = {mac.identity(d) for d in mac.ids()}
    connected = [d for d in original['displays'] if d['uuid'] in live]
    if len(connected) != len(original['displays']):
        print('部分原显示器已断开；其设置备份仍保留，重新连接后可手动 restore。', flush=True)
    if not connected:
        return
    ids = {d['id'] for d in connected}
    if any(d['mirror_of'] and d['mirror_of'] not in ids for d in connected):
        raise errors.HiDPIError('原镜像组不完整；请连接原显示器后从备份恢复。')
    mac.restore(dict(original, displays=connected))


def capture_original(mac):
    original = mac.snapshot(allow_empty=True)
    # macOS creates a transient fallback desktop when no monitor is attached.
    # Chromium also identifies this model as the system virtual display. It
    # vanishes/reappears with different IDs and modes; never replay it as EDID
    # hardware. Its previous state remains described in the backup metadata.
    transient = [d for d in original['displays'] if
                 d['vendor'] == 0x756E6B6E and d['model'] == 0x76697274]
    stable = [d for d in original['displays'] if d not in transient]
    if not stable:
        return dict(original, schema=2, headless=True, displays=[], system_fallback=transient)
    return dict(original, displays=stable)


def run(mac, args):
    validate_options(args)
    original = capture_original(mac)
    backup = backups.write_backup(original, args.backup_dir)
    print(f'创建虚拟屏幕前已备份：{backup}', flush=True)
    display = VirtualDisplay(mac, args.size, args.refresh)
    failure = None
    with runtime.stop_signals() as stopping:
        try:
            display_id = display.start()
            print(f'虚拟屏幕已核验，ID={display_id}：' + display_modes.describe(mac.current(display_id)), flush=True)
            print('远程客户端可选择 HiDPI Virtual Display；不需要 HDMI 设备。', flush=True)
            expected = dict(mac.current(display_id), hz=args.refresh)
            runtime.preview(mac, display_id, expected, args.seconds, args.keep, stopping, mode_check=mode_matches)
        except BaseException as error:
            failure = error
            print(f'虚拟屏幕操作失败：{error}', flush=True)
            raise
        finally:
            try:
                try:
                    display.close()
                finally:
                    restore_connected(mac, original)
                print('虚拟屏幕已移除，已恢复仍连接的原屏幕。', flush=True)
            except Exception as error:
                print(f'清理未完全完成：{error}。备份保留在 {backup}', flush=True)
                if failure is None:
                    raise
