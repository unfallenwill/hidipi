"""Process locks, shutdown signals and preview lifetime."""
import contextlib
import fcntl
import os
import select
import signal
import sys
import time
from . import errors, macos, menubar, modes as display_modes, state


@contextlib.contextmanager
def file_lock(name, message, timeout=0):
    """Hold a stable per-user lock, optionally waiting for process cleanup."""
    root = state.config_dir()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = root / name
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a+') as lock:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise errors.HiDPIError(message) from None
                time.sleep(0.2)
        yield


def single_instance(directory=None, timeout=0):
    # The backup directory deliberately does not affect lock identity.
    return file_lock('operation.lock',
        '另一个 HiDPI 操作正在运行。请先在其终端按 Ctrl+C，再恢复备份。', timeout)


def autostart_lock():
    # Separate from the display lock: the child must acquire that at bootstrap.
    return file_lock('autostart.lock', '另一个自启动安装或卸载操作正在运行，请稍后重试。')


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


def preview(mac, display, expected, seconds, keep, stopping, mode_check=display_modes.mode_matches):
    macos.hide_dock_icon()
    # Cosmetic icon; degrades to None outside a desktop session or on failure.
    bar = menubar.start(display_modes.describe(expected),
                        lambda: stopping.__setitem__('stop', True))
    try:
        _preview_loop(mac, display, expected, seconds, keep, stopping, mode_check)
    finally:
        menubar.stop(bar)


def _preview_loop(mac, display, expected, seconds, keep, stopping, mode_check):
    deadline = time.monotonic() + seconds
    interactive = sys.stdin.isatty()
    if keep:
        print('HiDPI 正在运行，按 Ctrl+C 恢复原设置。', flush=True)
    else:
        print(f'{seconds} 秒后自动恢复。' + ('输入 y 并回车可继续使用，随后按 Ctrl+C 恢复。'
              if interactive else '当前为非交互运行，倒计时后恢复。'), flush=True)
    while not stopping['stop']:
        if display not in mac.ids():
            raise errors.HiDPIError('目标显示器已断开。重新连接后可使用 restore 命令恢复。')
        if not mode_check(mac.current(display), expected):
            raise errors.HiDPIError('显示模式发生变化，结束运行并恢复备份。')
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
