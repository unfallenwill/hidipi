#!/usr/bin/env python3
"""Dependency-free macOS HiDPI tool. Run `uv run hidpi --help`."""
import argparse
import contextlib
import ctypes as C
import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import platform
import select
import signal
import sys
import tempfile
import time
import uuid

from . import state


P = C.c_void_p
U = C.c_uint32
I = C.c_int32
D = C.c_double


class Pair(C.Structure):
    _fields_ = [("x", D), ("y", D)]


class Rect(C.Structure):
    _fields_ = [("origin", Pair), ("size", Pair)]


class HiDPIError(Exception):
    pass


def check(code, operation):
    if code:
        raise HiDPIError(f"{operation} 失败，CoreGraphics 错误码 {code}")


def bind(lib, name, result, *args):
    fn = getattr(lib, name)
    fn.restype, fn.argtypes = result, args
    return fn


def mode_matches(actual, expected):
    return bool(actual) and all(actual[k] == expected[k] for k in
                               ("width", "height", "pixel_width", "pixel_height")) and (
        abs(actual["hz"] - expected["hz"]) < 0.6)


def is_hidpi(mode):
    return bool(mode) and mode["pixel_width"] >= 2 * mode["width"] and (
        mode["pixel_height"] >= 2 * mode["height"])


def describe(mode):
    if not mode:
        return "模式暂不可用"
    rate = f'{mode["hz"]:g} Hz' if mode['hz'] else '刷新率未报告'
    return (f'{mode["width"]}×{mode["height"]}，渲染 {mode["pixel_width"]}×'
            f'{mode["pixel_height"]}，{rate}，'
            f'{"HiDPI" if is_hidpi(mode) else "普通 DPI"}')


class Mac:
    def __init__(self):
        if sys.platform != "darwin":
            raise HiDPIError("此工具仅支持 macOS。")
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
                raise HiDPIError('当前 macOS 未提供显示器 UUID 接口，无法可靠备份。') from None
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
                from .virtual import screen_mode
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
            raise HiDPIError(f"无法取得显示器 {display} 的 UUID；不能可靠备份。")
        string = self.cf.CFUUIDCreateString(None, value)
        try:
            buf = C.create_string_buffer(128)
            if not self.cf.CFStringGetCString(string, buf, len(buf), 0x08000100):
                raise HiDPIError("无法解码显示器 UUID")
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
            raise HiDPIError("未读取到在线显示器。请在已登录桌面的本机终端运行；沙箱/SSH 会话可能无法访问 WindowServer。")
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
            candidates = [m for m in modes if mode_matches(self.info(m), expected)]
            if not candidates:
                raise HiDPIError("指定模式已不可用；尚未切换。")
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
                    raise HiDPIError(f'备份中的显示器 {saved["uuid"]} 未连接；请重新连接后恢复。')
                mode = saved["mode"]
                if not mode:
                    raise HiDPIError("备份缺少原始模式，无法完整恢复。")
                with self.modes(display) as modes:
                    matches = [m for m in modes if mode_matches(self.info(m), mode)]
                    if not matches:
                        raise HiDPIError(f'显示器 {display} 的原始模式当前不可用：{describe(mode)}')
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
                            raise HiDPIError("备份中的镜像源不完整。")
                        check(self.cg.CGConfigureDisplayMirrorOfDisplay(config, display, source[0]), "恢复原镜像")
            self.wait_until(lambda: all(
                mode_matches(self.current(d), s["mode"]) and
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
        raise HiDPIError(error)


def validate_backup(data):
    if isinstance(data, dict) and data.get('schema') == 2 and data.get('headless') is True and data.get('displays') == []:
        return data
    if not isinstance(data, dict) or data.get("schema") != 1:
        raise HiDPIError("不支持的备份格式。")
    displays = data.get("displays")
    if not isinstance(displays, list) or not 1 <= len(displays) <= 128:
        raise HiDPIError("备份显示器列表无效。")
    ids, uuids = set(), set()
    try:
        for item in displays:
            if not isinstance(item, dict):
                raise ValueError()
            if type(item["id"]) is not int or not 0 < item["id"] < 2**32:
                raise ValueError()
            if item["id"] in ids or item["uuid"] in uuids:
                raise ValueError()
            uuid.UUID(item["uuid"])
            ids.add(item["id"])
            uuids.add(item["uuid"])
            if len(item["origin"]) != 2 or any(type(n) is not int or abs(n) >= 2**31 for n in item["origin"]):
                raise ValueError()
            if type(item["mirror_of"]) is not int:
                raise ValueError()
            mode = item["mode"]
            for key in ("width", "height", "pixel_width", "pixel_height"):
                if type(mode[key]) is not int or not 0 < mode[key] <= 65536:
                    raise ValueError()
            if type(mode["mode_id"]) is not int:
                raise ValueError()
            if not isinstance(mode["hz"], (int, float)) or not math.isfinite(mode["hz"]) or not 0 <= mode["hz"] <= 1000:
                raise ValueError()
        if any(d["mirror_of"] and (d["mirror_of"] not in ids or d["mirror_of"] == d["id"]) for d in displays):
            raise ValueError()
    except (KeyError, TypeError, ValueError, AttributeError):
        raise HiDPIError("备份数据不完整或数值无效；未修改显示器。") from None
    return data


def write_backup(snapshot, directory):
    validate_backup(snapshot)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    name = datetime.datetime.now().strftime("display-%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8] + '.json'
    path = directory / name
    fd, temporary = tempfile.mkstemp(prefix='.backup-', dir=str(directory))
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(snapshot, out, ensure_ascii=False, indent=2, allow_nan=False)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(str(directory), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        # Read back before any change to the display.
        if validate_backup(json.loads(path.read_text())) != snapshot:
            raise HiDPIError("备份回读不一致；取消切换。")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return path


@contextlib.contextmanager
def single_instance(directory):
    # One per-user lock even when callers choose different backup directories.
    lock_path = Path(tempfile.gettempdir()) / f'hidpi-cli-{os.getuid()}.lock'
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise HiDPIError("另一个 HiDPI 操作正在运行。请先在其终端按 Ctrl+C，再恢复备份。") from None
        yield


def size_value(value):
    try:
        w, h = map(int, value.lower().replace('×', 'x').split('x'))
        if not (640 <= w <= 7680 and 480 <= h <= 4320):
            raise ValueError()
        return w, h
    except ValueError:
        raise argparse.ArgumentTypeError("请使用 1920x1080 格式；宽 640–7680、高 480–4320。")


def choose_mode(modes, size, current, refresh=None):
    candidates = [m for m in modes if m['usable'] and is_hidpi(m) and
                  (m['width'], m['height']) == tuple(size) and
                  (refresh is None or abs(m['hz'] - refresh) < 0.6)]
    if not candidates:
        requested = f'{size[0]}×{size[1]}' + (f' @ {refresh:g} Hz' if refresh else '')
        raise HiDPIError(f'系统没有提供 {requested} 的 HiDPI 模式；未修改设置。'
                         '请运行 list 选择已有模式。本工具不会伪造显示器配置。')
    # Preserve the existing refresh rate when possible; otherwise use the
    # highest available refresh rate. Never silently select a LoDPI variant.
    return min(candidates, key=lambda m: (abs(m['hz'] - current['hz']) >= 0.6, -m['hz']))


@contextlib.contextmanager
def stop_signals():
    state = {'stop': False}
    def stop(signum, frame):
        state['stop'] = True
    previous = {sig: signal.signal(sig, stop) for sig in
                (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        yield state
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def preview(mac, display, expected, seconds, keep, stopping, mode_check=mode_matches):
    deadline = time.monotonic() + seconds
    interactive = sys.stdin.isatty()
    if keep:
        print('HiDPI 正在运行，按 Ctrl+C 恢复原设置。', flush=True)
    else:
        print(f'{seconds} 秒后自动恢复。' + ('输入 y 并回车可继续使用，随后按 Ctrl+C 恢复。'
              if interactive else '当前为非交互运行，倒计时后恢复。'), flush=True)
    while not stopping['stop']:
        if display not in mac.ids():
            raise HiDPIError('目标显示器已断开。重新连接后可使用 restore 命令恢复。')
        if not mode_check(mac.current(display), expected):
            raise HiDPIError('显示模式发生变化，结束运行并恢复备份。')
        if not keep and time.monotonic() >= deadline:
            return
        if interactive and not keep and select.select([sys.stdin], [], [], 0)[0]:
            answer = sys.stdin.readline().strip().lower()
            if answer == 'y':
                keep = True
                print('继续使用中；请保留此终端，按 Ctrl+C 恢复。', flush=True)
            else:
                return
        mac.pump(0.2)


def enable_hidpi(mac, args):
    original = mac.snapshot()
    if getattr(args, 'display_uuid', None):
        target = next((d for d in original['displays'] if
                       d['uuid'].lower() == args.display_uuid.lower()), None)
        if not target:
            raise HiDPIError('指定 UUID 的显示器未连接。')
    elif args.display is None:
        if len(original['displays']) != 1:
            raise HiDPIError('检测到多台显示器，请通过 --display 指定 list 中的 ID。')
        target = original['displays'][0]
    else:
        target = next((d for d in original['displays'] if d['id'] == args.display), None)
        if not target:
            raise HiDPIError('指定显示器未连接。')
    if target['in_mirror_set']:
        raise HiDPIError('目标显示器正在镜像。请先在系统设置中解除镜像，再切换 HiDPI。')
    if not target['mode']:
        raise HiDPIError('无法读取原始模式，不能安全备份；取消操作。')
    display = target['id']
    size = args.size or (target['mode']['width'], target['mode']['height'])
    with mac.modes(display) as pointers:
        wanted = choose_mode([mac.info(p) for p in pointers], size, target['mode'], args.refresh)
    print('原始：' + describe(target['mode']))
    print('目标：' + describe(wanted))
    if mode_matches(target['mode'], wanted):
        print('已处于指定 HiDPI 模式，无需修改。')
        return
    if abs(wanted['hz'] - target['mode']['hz']) >= 0.6:
        print(f'注意：刷新率将从 {target["mode"]["hz"]:g} Hz 变为 {wanted["hz"]:g} Hz。')
    backup = write_backup(original, args.backup_dir)
    print(f'已备份并回读核验：{backup.resolve()}', flush=True)
    print(f'独立恢复命令：hidpi restore {backup.resolve()}', flush=True)
    # Install handlers before modifying anything. Signals set a flag instead
    # of interrupting a CoreGraphics transaction or the finally restoration.
    with stop_signals() as stopping:
        try:
            mac.set_mode(display, wanted)
            mac.wait_until(lambda: mode_matches(mac.current(display), wanted),
                           '系统未切换到指定 HiDPI 模式，正在恢复', 5)
            print('已核验：' + describe(mac.current(display)), flush=True)
            preview(mac, display, wanted, args.seconds, args.keep, stopping)
        finally:
            print('\n正在恢复原设置……', flush=True)
            try:
                mac.restore(original)
            except Exception as error:
                print(f'自动恢复未完成：{error}\n备份保留在：{backup.resolve()}\n'
                      f'请重新连接原显示器后运行：hidpi restore {backup.resolve()}', file=sys.stderr)
                raise
            print('已恢复并核验原始分辨率、刷新率、镜像与排列。', flush=True)


def list_displays(mac, all_modes=False):
    snapshot = mac.snapshot()
    for display in snapshot["displays"]:
        did = display['id']
        print(f'显示器 {did}  UUID={display["uuid"]}  '
              f'{"主屏" if display["main"] else "副屏"}  '
              f'vendor={display["vendor"]} model={display["model"]}')
        print('  当前：' + describe(display['mode']))
        with mac.modes(did) as pointers:
            modes = [mac.info(p) for p in pointers]
        seen = set()
        for mode in sorted(modes, key=lambda m: (m['width'], m['height'], m['hz'], m['pixel_width'])):
            signature = tuple(mode[k] for k in ('width', 'height', 'pixel_width', 'pixel_height', 'hz'))
            if mode['usable'] and signature not in seen and (all_modes or is_hidpi(mode)):
                print('    ' + describe(mode))
                seen.add(signature)
        if not seen:
            if display['vendor'] == 0xF0F0:
                print('  HiDPI Virtual Display：虚拟屏幕按创建参数运行，无可切换模式列表。')
            else:
                print('  系统未提供可用的 HiDPI 模式；本工具不会伪造不支持的模式。')


def main():
    parser = argparse.ArgumentParser(description='免费 macOS HiDPI 工具：自动备份、限时预览、退出恢复。')
    parser.add_argument('--backup-dir', type=Path, default=state.backup_dir(),
                        help='备份目录（默认 ~/.config/hidpi-cli/backups）')
    sub = parser.add_subparsers(dest='command', required=True)
    listing = sub.add_parser('list', help='只读：列出显示器和 HiDPI 模式')
    listing.add_argument('--all', action='store_true', help='也显示普通 DPI 模式')
    sub.add_parser('backup', help='只备份，不修改')
    sub.add_parser('paths', help='显示用户配置、备份和日志目录')
    restore = sub.add_parser('restore', help='从指定 JSON 备份恢复')
    restore.add_argument('file', type=Path)
    enable = sub.add_parser('enable', help='备份后开启 HiDPI，退出自动恢复')
    selection = enable.add_mutually_exclusive_group()
    selection.add_argument('--display', type=int, help='list 命令中的显示器 ID；只有一台时可省略')
    selection.add_argument('--display-uuid', help='跨重启稳定的显示器 UUID')
    enable.add_argument('--size', type=size_value, help='界面逻辑尺寸，如 1920x1080；默认保持当前界面尺寸')
    enable.add_argument('--refresh', type=float, help='指定刷新率；不支持时直接报错，不降低刷新率')
    enable.add_argument('--seconds', type=int, default=20, help='预览秒数（5–120，默认 20）')
    enable.add_argument('--keep', action='store_true', help='跳过预览倒计时，保持运行直到 Ctrl+C')
    enable.add_argument('--wait-display', type=int, default=0, help='启动时等待指定显示器就绪的秒数（0–120）')
    from . import autostart
    autostart.add_parser(sub)
    from . import virtual
    virtual.add_parser(sub)
    args = parser.parse_args()
    try:
        if args.command == 'paths':
            state.show_paths()
            return 0
        if args.command == 'autostart':
            autostart.handle(args)
            return 0
        mac = Mac()
        if args.command == 'list':
            list_displays(mac, args.all)
        else:
            with single_instance(args.backup_dir):
                if args.command == 'virtual':
                    virtual.run(mac, args)
                elif args.command == 'backup':
                    print('备份：' + str(write_backup(mac.snapshot(), args.backup_dir)))
                elif args.command == 'restore':
                    saved = validate_backup(json.loads(args.file.read_text()))
                    path = write_backup(mac.snapshot(), args.backup_dir)
                    print(f'恢复前的状态也已备份：{path}', flush=True)
                    mac.restore(saved)
                    print('已恢复并核验原始分辨率、刷新率、镜像与排列。')
                else:
                    if not 5 <= args.seconds <= 120:
                        raise HiDPIError('--seconds 必须在 5–120 之间。')
                    if args.refresh is not None and (not math.isfinite(args.refresh) or not 0 < args.refresh <= 1000):
                        raise HiDPIError('--refresh 必须是 0–1000 范围内的正数。')
                    if not 0 <= args.wait_display <= 120:
                        raise HiDPIError('--wait-display 必须在 0–120 之间。')
                    if args.wait_display and not autostart.wait_for_display(mac, args):
                        return 0
                    enable_hidpi(mac, args)
        return 0
    except (HiDPIError, OSError, ValueError) as exc:
        print(f'错误：{exc}', file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('\n已取消。', file=sys.stderr)
        return 130


if __name__ == '__main__':
    sys.exit(main())
